{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |This module provides an implementation of indexes that may be persisted to
-- disk.  Keys in the index are effectively fixed-length byte strings.  The
-- index is implemented as a Trie, where each branching node has degree 256.
--
-- TODO: It is likely desirable to replace this with a B-Tree in many applications,
-- especially where the keys are randomly distributed.
module Concordium.GlobalState.Persistent.Trie where

import Data.Fix
import qualified Data.Vector as V
import Data.List(intercalate,stripPrefix)
import Data.Word
import Data.Functor.Foldable hiding (Nil)
import Data.Bifunctor
import Control.Monad
import Data.Serialize
import qualified Data.ByteString as BS
import qualified Data.ByteString.Short as SBS
import Data.Either
import qualified Data.Map.Strict as Map
import qualified Data.FixedByteString as FBS

import Concordium.Types (AccountAddress, BakerId(..), DelegatorId(..), AccountIndex(..), ModuleRef(..))
import Concordium.Utils
import qualified Concordium.Crypto.SHA256 as SHA256
import qualified Concordium.Crypto.BlsSignature as Bls
import qualified Concordium.ID.Types as IDTypes

import Concordium.GlobalState.Persistent.MonadicRecursive
import Concordium.GlobalState.Persistent.BlobStore
    ( cacheBufferedBlobbed,
      BlobRef,
      BlobStorable(..),
      BufferedBlobbed,
      Cacheable(..),
      FixShowable(..),
      MonadBlobStore,
      Nullable(..) )

class FixedTrieKey a where
    -- |Unpack a key to a list of bytes.
    -- The length of the list must be independent of the value.
    unpackKey :: a -> SBS.ShortByteString
    default unpackKey :: (Serialize a) => a -> SBS.ShortByteString
    unpackKey = SBS.toShort . encode
    -- |Pack a key from a list of bytes.
    packKey :: SBS.ShortByteString -> a
    default packKey :: (Serialize a) => SBS.ShortByteString -> a
    packKey = fromRight (error "FixedTrieKey: deserialization failed") . decode . SBS.fromShort

instance FixedTrieKey Word64
instance FixedTrieKey Word32
instance FixedTrieKey SHA256.Hash where
    unpackKey (SHA256.Hash fbs) = FBS.toShortByteString fbs
    packKey = SHA256.Hash . FBS.fromShortByteString
deriving via SHA256.Hash instance FixedTrieKey ModuleRef
instance FixedTrieKey AccountAddress
deriving via Word64 instance FixedTrieKey BakerId
deriving via Word64 instance FixedTrieKey DelegatorId
instance FixedTrieKey Bls.PublicKey -- FIXME: This is a bad instance. Serialization of these is expensive.

instance FixedTrieKey IDTypes.RawCredentialRegistrationID where
  unpackKey (IDTypes.RawCredentialRegistrationID x) = FBS.toShortByteString x
  packKey = IDTypes.RawCredentialRegistrationID . FBS.fromShortByteString

-- |Class for Trie keys that respect the 'Ord' instance.
-- That is, @a `compare` b == unpackKey a `compare` unpackKey b@.
class (Ord a, FixedTrieKey a) => OrdFixedTrieKey a
instance OrdFixedTrieKey Word64
instance OrdFixedTrieKey Word32
deriving via Word64 instance OrdFixedTrieKey BakerId
deriving via Word64 instance OrdFixedTrieKey DelegatorId

-- |Trie with keys all of same fixed length treated as lists of bytes.
-- The first parameter of 'TrieF' is the type of keys, which should
-- by an instance of 'FixedTrieKey'.
-- The second parameter is the type of values.
-- The third parameter is the recursive type argument: a type for Tries
-- is obtained by applying a fixed-point combinator to @TrieF k v@.
data TrieF k v r
    = Branch {-# UNPACK #-} !(V.Vector (Nullable r))
    -- ^Branch on the next byte of the key (256, possibly null children)
    | Stem {-# UNPACK #-} !SBS.ShortByteString !r
    -- ^The next bytes of the key are given
    | Tip !v
    -- ^A value
    deriving (Show, Functor, Foldable, Traversable)

-- |Render a 'TrieF', where the children have already been rendered
-- as 'String's.
showTrieFString :: Show v => TrieF k v String -> String
showTrieFString (Branch vec) = "[ " ++ ss (0 :: Int) (V.toList vec) ++ "]"
    where
        ss _ [] = ""
        ss i (Null:r) = ss (i+1) r
        ss i (Some v:r) = show i ++ ":" ++ v ++ "; " ++ ss (i+1) r
showTrieFString (Stem l r) = intercalate ":" (show <$> SBS.unpack l) ++ r
showTrieFString (Tip v) = show v

instance Bifunctor (TrieF k) where
    first _ (Branch vec) = Branch vec
    first _ (Stem pref r) = Stem pref r
    first f (Tip v) = Tip (f v)
    second = fmap

instance (Serialize r, Serialize (Nullable r), Serialize v) => Serialize (TrieF k v r) where
    put (Branch vec) = do
        putWord8 1
        forM_ vec put
    put (Tip v) = putWord8 2 >> put v
    put (Stem l r) = do
        let len = SBS.length l
        if len <= 251 then
            putWord8 (3 + fromIntegral len)
        else do
            putWord8 255
            putWord64be (fromIntegral len)
        putShortByteString l
        put r
    get = getWord8 >>= \case
        0 -> fail "Empty trie"
        1 -> Branch . V.fromList <$> replicateM 256 get
        2 -> Tip <$> get
        v -> do
            len <- if v == 255 then
                    fromIntegral <$> getWord64be
                else
                    return (fromIntegral (v - 3))
            Stem <$> getShortByteString len <*> get

instance (BlobStorable m r, BlobStorable m (Nullable r), BlobStorable m v) => BlobStorable m (TrieF k v r) where
    storeUpdate (Branch vec) = do
        pvec <- mapM storeUpdate vec
        return $!! (putWord8 1 >> sequence_ (fst <$> pvec), Branch (snd <$> pvec))
    storeUpdate (Tip v) = do
        (pv, v') <- storeUpdate v
        return $!! (putWord8 2 >> pv, Tip v')
    storeUpdate (Stem l r) = do
        (pr, r') <- storeUpdate r
        let putter = do
                let len = SBS.length l
                if len <= 251 then
                    putWord8 (3 + fromIntegral len)
                else do
                    putWord8 255
                    putWord64be (fromIntegral len)
                putShortByteString l
                pr
        return $!! (putter, Stem l r')
    store t = fst <$> storeUpdate t
    load = getWord8 >>= \case
        0 -> fail "Empty trie"
        1 -> do
            branchms <- replicateM 256 load
            return $! Branch . V.fromList <$> sequence branchms
        2 -> fmap Tip <$> load
        v -> do
            len <- if v == 255 then
                    fromIntegral <$> getWord64be
                else
                    return (fromIntegral (v - 3))
            l <- getShortByteString len
            r <- load
            return $! (Stem l <$> r)


-- |@Trie k v@ is defined as a simple fixed-point of @TrieF k v@.
newtype Trie k v = Trie (TrieF k v (Trie k v)) deriving (Show)
type instance Base (Trie k v) = TrieF k v
instance Recursive (Trie k v) where
    project (Trie t) = t
instance Corecursive (Trie k v) where
    embed = Trie
instance (Monad m) => MRecursive m (Trie k v) where
    mproject = pure . project
instance (Monad m) => MCorecursive m (Trie k v) where
    membed = pure . embed

instance Functor (Trie k) where
    fmap f = hoist (first f)

-- * Trie operations
--
-- These operations are defined on a type @t@ that can be unrolled/rolled in a monad
-- @m@ to type @TrieF k v t@.  (Unrolling is provided by the 'mproject' operation of
-- 'MRecursive', and rolling is provided by the 'membed' operation of 'MCorecursive'.)
-- The rolling and unrolling can correspond to simply adding or removing constructors
-- (as for 'Trie'), but also correspond to creating and traversing disk references.

-- |Retrieve the value (if any) corresponding to a given key.
-- TODO: With bytestring-0.11.3.0 and later, the operations on 'SBS.ShortByteString' can
-- be used to implement this more efficiently without unpacking.
lookupF :: (MRecursive m t, Base t ~ TrieF k v, FixedTrieKey k) => k -> t -> m (Maybe v)
lookupF k = lu (SBS.unpack $ unpackKey k) <=< mproject
    where
        lu [] (Tip v) = pure (Just v)
        lu _ (Tip _) = pure Nothing
        lu key (Stem pref r) = case stripPrefix (SBS.unpack pref) key of
            Nothing -> pure Nothing
            Just key' -> mproject r >>= lu key'
        lu [] (Branch _) = pure Nothing
        lu (w:key') (Branch vec) = case vec V.! fromIntegral w of
            Null -> return Nothing
            Some r -> mproject r >>= lu key'

-- |An auxiliary datatype used by lookupPrefix.
data FollowStemResult =
  Equal -- ^ The key and the stem are equal.
  | KeyIsPrefix -- ^ Key is a strict prefix of the stem.
  | StemIsPrefix {remainingKey :: [Word8]}
  -- ^Stem is a prefix of the key. The remaining key is returned. If it is empty
  -- then key and stem are equal.
  | Diff -- ^The key and stem differ at some point.

-- |Given the key (first argument) and stem (second argument) of the trie
-- compare them and return the result of the comparison. See 'FollowStem'
-- datatype documentation for the meaning of return values.
followStem :: [Word8] -> [Word8] -> FollowStemResult
followStem = go
  where go (keyStep:remainingKey) (stemStep:remainingStem)
            | keyStep /= stemStep = Diff
            | otherwise = go remainingKey remainingStem
        go [] (_:_) = KeyIsPrefix
        go remainingKey [] = StemIsPrefix {..}

-- |Retrieve all the keys and values with the given prefix in the Trie.
-- In case of multiple return values the order of keys is not specified.
lookupPrefixF :: (MRecursive m t, Base t ~ TrieF k v, FixedTrieKey k) => [Word8] -> t -> m [(k, v)]
lookupPrefixF ks = lu [] ks <=< mproject
    where
        lu prefix [] (Tip v) = pure [(packKey $ SBS.pack prefix, v)]
        lu _ _ (Tip _) = pure []
        lu prefix key (Stem pref r) = case followStem key (SBS.unpack pref) of
            StemIsPrefix{..} -> mproject r >>= lu (prefix ++ SBS.unpack pref) remainingKey
            Diff -> pure []
            Equal -> mproject r >>= lu (prefix ++ SBS.unpack pref) []
            KeyIsPrefix -> mproject r >>= collect (prefix ++ SBS.unpack pref)
        lu prefix [] b@(Branch _) = collect prefix b
        lu prefix (w:key') (Branch vec) = case vec V.! fromIntegral w of
            Null -> return []
            Some r -> mproject r >>= lu (prefix ++ [w]) key'

        collect keyPrefix (Tip v) = return [(packKey $ SBS.pack keyPrefix, v)]
        collect keyPrefix (Stem pref r) = collect (keyPrefix ++ SBS.unpack pref) =<< mproject r
        collect keyPrefix (Branch vec) = do
            let
                handleBranch acc _ Null = return acc
                handleBranch acc i (Some r) = do
                  childList <- mproject r >>= collect (keyPrefix ++ [fromIntegral i])
                  return (childList ++ acc)
            V.ifoldM handleBranch [] vec


-- |Traverse the trie, applying a function to each key value pair and concatenating the
-- results monoidally.  Keys are traversed from lowest to highest in their byte-wise
-- representation.
mapReduceF :: (MRecursive m t, Base t ~ TrieF k v, FixedTrieKey k, Monoid a) => (k -> v -> m a) -> t -> m a
mapReduceF mfun = mr [] <=< mproject
    where
        mr keyPrefix (Tip v) = mfun (packKey $ SBS.pack keyPrefix) v
        mr keyPrefix (Stem pref r) = mr (keyPrefix ++ SBS.unpack pref) =<< mproject r
        mr keyPrefix (Branch vec) = do
            let
                handleBranch _ Null = return mempty
                handleBranch i (Some r) = mr (keyPrefix ++ [fromIntegral i]) =<< mproject r
            mconcat . V.toList <$> V.imapM handleBranch vec

-- |Essentially 'mapReduceF', but the constraint implies that keys are traversed lowest to
-- highest with respect to their 'Ord' instance.
mapReduceAscF :: (MRecursive m t, Base t ~ TrieF k v, OrdFixedTrieKey k, Monoid a) => (k -> v -> m a) -> t -> m a
mapReduceAscF = mapReduceF

-- |Compute the common prefix and distinct suffixes of two lists.
commonPrefix :: (Eq a) => [a] -> [a] -> ([a], [a], [a])
commonPrefix [] [] = ([], [], [])
commonPrefix l1@(h1:t1) l2@(h2:t2)
    | h1 == h2 = let ~(p,r1,r2) = commonPrefix t1 t2 in (h1:p,r1,r2)
    | otherwise = ([], l1, l2)
commonPrefix l1 l2 = ([], l1, l2)

-- |Representation of an alteration to make in a map at some key.
data Alteration v
    = NoChange
    -- ^Leave the value as it was
    | Remove
    -- ^Remove the entry
    | Insert !v
    -- ^Insert or replace the old value with the given one

-- |A generalised update function for updating the value of the map at a given key.
-- 'alterM' takes the key to alter and an update function.  The return value is @Nothing@
-- if the result would be an empty trie.
--
-- If the key is already present in the map, the update function is called with @Just v@;
-- otherwise it is called with @Nothing@.  The return value of the update function determines
-- whether the key is added, removed, or no change occurs.  The update operation is monadic,
-- which can allow for values to be stored as references, which are written out as part of the
-- update.  The update function can also return a value that is passed back to the caller.
--
-- Note that, while @NoChange@ is theoretically redundant it provides an important optimisation
-- when the trie will be stored on disk: no writes are needed when no change is made.
--
-- The trie implementation is intended to be persistent in that the old trie will still be valid
-- and represent the same map after an update is made.  Thus, there is no explicit reclamation of
-- storage.
alterM :: forall m t k v a. (MRecursive m t, MCorecursive m t, Base t ~ TrieF k v, FixedTrieKey k) => k -> (Maybe v -> m (a, Alteration v)) -> t -> m (a, Maybe t)
alterM k upd pt0 = do
        t0 <- mproject pt0
        let
            nochange0 res = return (res, Just pt0)
            remove0 res = return (res, Nothing)
            update0 res [] t = return (res, Just t)
            update0 res key t = do
                t' <- membed (Stem (SBS.pack key) t)
                return (res, Just t')
        aM (SBS.unpack $ unpackKey k) t0 nochange0 remove0 update0
    where
        aM :: [Word8] -> TrieF k v t -> (a -> m z) -> (a -> m z) -> (a -> [Word8] -> t -> m z) -> m z
        aM [] (Tip v0) nochange remove update = upd (Just v0) >>= \case
            (res, Insert v) -> membed (Tip v) >>= update res []
            (res, Remove) -> remove res
            (res, NoChange) -> nochange res
        aM _ (Tip _) _ _ _ = error "Key too long"
        aM [] (Branch _) _ _ _ = error "Key too short"
        aM (kw:key') (Branch vec) nochange remove update = case vec V.! fromIntegral kw of
            Null -> upd Nothing >>= \case
                (res, Insert v) -> do
                    tip <- membed (Tip v)
                    stem <- if null key' then return tip else membed (Stem (SBS.pack key') tip)
                    let vec' = vec V.// [(fromIntegral kw, Some stem)]
                    branch <- membed (Branch vec')
                    update res [] branch
                (res, _) -> nochange res
            Some r -> do
                b <- mproject r
                let
                    myupdate res [] t = do
                        let vec' = vec V.// [(fromIntegral kw, Some t)]
                        membed (Branch vec') >>= update res []
                    myupdate res skey t' = do
                        t <- membed (Stem (SBS.pack skey) t')
                        let vec' = vec V.// [(fromIntegral kw, Some t)]
                        membed (Branch vec') >>= update res []
                    myremove res = do
                        let
                            vec' = vec V.// [(fromIntegral kw, Null)]
                            nobranches _ [] = remove res
                            nobranches i (Null:vv) = nobranches (i+1) vv
                            nobranches i (Some x:vv) = onebranch i x vv
                            onebranch i x [] = update res [i] x
                            onebranch i x (Null:vv) = onebranch i x vv
                            onebranch _ _ (Some _:_) = membed (Branch vec') >>= update res []
                        nobranches 0 (V.toList vec')
                aM key' b nochange myremove myupdate
        aM key (Stem pref r) nochange remove update = case commonPrefix key (SBS.unpack pref) of
                (_, key', []) -> do
                    t <- mproject r
                    let myupdate res skey t' = update res (SBS.unpack pref ++ skey) t'
                    aM key' t nochange remove myupdate
                (_, [], (_:_)) -> error "Key too short"
                (pref', (hk:tk), (hr:tr)) -> upd Nothing >>= \case
                    (res, Insert v) -> do
                        rbranch <- if null tr then return r else membed (Stem (SBS.pack tr) r)
                        ktip <- membed (Tip v)
                        kbranch <- if null tk then return ktip else membed (Stem (SBS.pack tk) ktip)
                        branches <- membed (Branch (V.replicate 256 Null V.// [(fromIntegral hr, Some rbranch), (fromIntegral hk, Some kbranch)] ))
                        update res pref' branches
                    (res, _) -> nochange res

-- |A trie constructed using the specified fixed-point combinator.
data TrieN fix k v
    = EmptyTrieN
    -- ^The empty trie
    | TrieN !Int !(fix (TrieF k v))
    -- ^A non empty trie with its size

instance (Show v, FixShowable fix) => Show (TrieN fix k v) where
    show EmptyTrieN = "EmptyTrieN"
    show (TrieN _ t) = showFix showTrieFString t

instance (BlobStorable m (fix (TrieF k v)), BlobStorable m v, Base (fix (TrieF k v)) ~ TrieF k v) => BlobStorable m (TrieN fix k v) where
    store EmptyTrieN = return (put (0 :: Int))
    store (TrieN size t) = do
        pt <- store t
        return $! (put size >> pt)
    storeUpdate v@EmptyTrieN = return (put (0 :: Int), v)
    storeUpdate (TrieN size t) = do
        (pt, t') <- storeUpdate t
        let bs = put size >> pt
            nt = TrieN size t'
        return $!! (bs, nt)
    load = do
        size <- get
        if size == 0 then
            return (return EmptyTrieN)
        else do
            mt <- load
            return $! (TrieN size <$> mt)

-- |The empty trie.
empty :: TrieN fix k v
empty = EmptyTrieN

-- |A singleton trie.
singleton :: (MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) => k -> v -> m (TrieN fix k v)
singleton k v = membed (Tip v) >>= membed . (Stem (unpackKey k)) >>= return . (TrieN 1)

-- |Insert/update a given key.
insert :: (MRecursive m (fix (TrieF k v)), MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) =>
    k -> v -> TrieN fix k v -> m (TrieN fix k v)
insert k v EmptyTrieN = singleton k v
insert k v (TrieN s t) = do
    let
        alt Nothing = return (True, Insert v)
        alt _ = return (False, Insert v)
    (inc, mt') <- alterM k alt t
    case mt' of
        Just t' -> return $! TrieN (if inc then s + 1 else s) t'
        Nothing -> return EmptyTrieN

-- |Remove a given key.
delete :: (MRecursive m (fix (TrieF k v)), MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) =>
    k -> TrieN fix k v -> m (TrieN fix k v)
delete _ EmptyTrieN = return EmptyTrieN
delete k (TrieN s t) = do
    let
        alt Nothing = return (False, Remove)
        alt _ = return (True, Remove)
    (dec, mt') <- alterM k alt t
    case mt' of
        Just t' -> return $! TrieN (if dec then s - 1 else s) t'
        Nothing -> return EmptyTrieN

-- |Lookup the value at a given key.
lookup :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) => k -> TrieN fix k v -> m (Maybe v)
lookup _ EmptyTrieN = return Nothing
lookup k (TrieN _ t) = lookupF k t

-- |Given a key prefix, look up all the keys and values where the key has the prefix.
-- In case of multiple return values the order of keys is not specified.
lookupPrefix :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) => [Word8] -> TrieN fix k v -> m [(k, v)]
lookupPrefix _ EmptyTrieN = return []
lookupPrefix k (TrieN _ t) = lookupPrefixF k t


-- |Alter the value at a particular key.
adjust :: (MRecursive m (fix (TrieF k v)), MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) =>
    (Maybe v -> m (a, Alteration v)) -> k -> TrieN fix k v -> m (a, TrieN fix k v)
adjust adj k EmptyTrieN = do
        (res, alter) <- adj Nothing
        case alter of
            Insert v -> (res, ) <$> singleton k v
            _ -> return (res, EmptyTrieN)
adjust adj k (TrieN s t) = do
    let
        ur Nothing (a, r@(Insert _)) = ((s+1, a), r)
        ur Nothing (a, r) = ((s, a), r)
        ur (Just _) (a, r@Remove) = ((s-1, a), r)
        ur (Just _) (a, r) = ((s, a), r)
        adj' i = ur i <$> adj i
    ((s', res), mt') <- alterM k adj' t
    case mt' of
        Just t' -> return (res, TrieN s' t')
        Nothing -> return (res, EmptyTrieN)

-- |Apply a monadic filter on a Trie.
-- TODO: This could be made more performant.
filterKeysM :: (MRecursive m (fix (TrieF k v)), MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) =>
    (k -> m Bool) -> TrieN fix k v -> m (TrieN fix k v)
filterKeysM f t = do
    k <- keys t
    keysToDelete <- filterM (fmap not . f) k
    foldM (flip delete) t keysToDelete

-- |Apply a monadic alteration to each element of a Trie.
-- The update function will be called once for each entry in the Trie.
-- The order is not specified.
alterMapM :: (MRecursive m (fix (TrieF k v)), MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) =>
    (k -> v -> m (Alteration v)) -> TrieN fix k v -> m (TrieN fix k v)
alterMapM upd t0 = do
    let makeAlteration (k, v) = (k,) <$> upd k v
    alterations <- mapM makeAlteration =<< toList t0
    let doAlteration t (_, NoChange) = return t
        doAlteration t (k, Remove) = delete k t
        doAlteration t (k, Insert v) = insert k v t
    foldM doAlteration t0 alterations

-- |Get the list of keys of a trie.
keys :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) => TrieN fix k v -> m [k]
keys EmptyTrieN = return []
keys (TrieN _ t) = mapReduceF (\k _ -> pure [k]) t

-- |Get the list of keys of a trie in ascending order.
keysAsc :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, OrdFixedTrieKey k) => TrieN fix k v -> m [k]
keysAsc = keys

-- |Get the list of keys and values in the trie.
toList :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) => TrieN fix k v -> m [(k, v)]
toList EmptyTrieN = return []
toList (TrieN _ t) = mapReduceF (\k v -> pure [(k, v)]) t

-- |Get the list of keys and values in the trie in ascending order of keys.
toAscList :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, OrdFixedTrieKey k) => TrieN fix k v -> m [(k, v)]
toAscList = toList


-- |Convert from a trie using 'Fix' (i.e. direct unrolling) to a trie using a different fixpoint combinator.
fromTrie :: forall m fix k v. (MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v) => TrieN Fix k v -> m (TrieN fix k v)
fromTrie EmptyTrieN = return EmptyTrieN
fromTrie (TrieN s t) = do
        t' <- conv t
        return (TrieN s t')
    where
        conv :: Fix (TrieF k v) -> m (fix (TrieF k v))
        conv t0 = do
            t1 <- mapM conv (project t0)
            membed t1

-- |Construct a trie from a list. (The order is not important.)
fromList :: (MCorecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k) => [(k,v)] -> m (TrieN fix k v)
fromList l = do
        t <- foldM (\tt (k,v) -> insert k v tt) empty l
        fromTrie t

-- |Convert a trie to a 'Map'.
toMap :: (MRecursive m (fix (TrieF k v)), Base (fix (TrieF k v)) ~ TrieF k v, FixedTrieKey k, Ord k) => TrieN fix k v -> m (Map.Map k v)
toMap EmptyTrieN = return Map.empty
toMap (TrieN _ t) = mapReduceF (\k v -> return (Map.singleton k v)) t

instance (MonadBlobStore m, BlobStorable m v, Cacheable m v) => Cacheable m (TrieN (BufferedBlobbed BlobRef) k v) where
    cache t@EmptyTrieN = return t
    cache (TrieN s t) = TrieN s <$> cacheBufferedBlobbed innerCache t
        where
            innerCache (Tip v) = Tip <$> cache v
            innerCache r = return r
