{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wall #-}
module SchedulerTests.AccountTransactionSpecs where

import Test.Hspec
import Test.HUnit

import Concordium.ID.Types
import qualified Concordium.Scheduler.Types as Types
import qualified Concordium.Scheduler.EnvironmentImplementation as Types
import qualified Acorn.Utils.Init as Init
import Concordium.Scheduler.Runner
import qualified Acorn.Parser.Runner as PR
import qualified Concordium.Scheduler as Sch
import qualified Concordium.Scheduler.Cost as Cost

import Concordium.GlobalState.Basic.BlockState
import Concordium.GlobalState.Account as Acc
import Concordium.GlobalState.Modules as Mod
import Concordium.GlobalState.Basic.Invariants
import qualified Concordium.GlobalState.Rewards as Rew
import Lens.Micro.Platform
import Control.Monad.IO.Class

import SchedulerTests.DummyData

import qualified Acorn.Core as Core

shouldReturnP :: Show a => IO a -> (a -> Bool) -> IO ()
shouldReturnP action f = action >>= (`shouldSatisfy` f)

initialAmount :: Types.Amount
initialAmount = fromIntegral (6 * Cost.deployCredential + 7 * Cost.checkHeader)

initialBlockState :: BlockState
initialBlockState = 
  -- NB: We need 6 * deploy account since we still charge the cost even if an
  -- account already exists (case 4 in the tests).
  emptyBlockState emptyBirkParameters Types.dummyCryptographicParameters &
    (blockAccounts .~ Acc.putAccount (mkAccount alesVK initialAmount) Acc.emptyAccounts) .
    (blockBank . Rew.totalGTU .~ initialAmount) .
    (blockModules .~ (let (_, _, gs) = Init.baseState in Mod.fromModuleList (Init.moduleList gs))) .
    (blockIdentityProviders .~ dummyIdentityProviders)

deployAccountCost :: Types.Energy
deployAccountCost = Cost.deployCredential + Cost.checkHeader

transactionsInput :: [TransactionJSON]
transactionsInput =
  [TJSON { payload = DeployCredential cdi1
         , metadata = makeHeader alesKP 1 deployAccountCost
         , keypair = alesKP
         }
  ,TJSON { payload = DeployCredential cdi2
         , metadata = makeHeader alesKP 2 deployAccountCost
         , keypair = alesKP
         }
  ,TJSON { payload = DeployCredential cdi3
         , metadata = makeHeader alesKP 3 deployAccountCost
         , keypair = alesKP
         }
  ,TJSON { payload = DeployCredential cdi8 -- should fail because repeated credential ID
         , metadata = makeHeader alesKP 4 deployAccountCost
         , keypair = alesKP
         }
  ,TJSON { payload = DeployCredential cdi6
         , metadata = makeHeader alesKP 5 deployAccountCost
         , keypair = alesKP
         }
  ,TJSON { payload = DeployCredential cdi7 -- deploy just a new predicate
         , metadata = makeHeader alesKP 6 deployAccountCost
         , keypair = alesKP
         }
  ,TJSON { payload = DeployCredential cdi4  -- should run out of gas (see initial amount on the sender account)
         , metadata = makeHeader alesKP 7 Cost.checkHeader
         , keypair = alesKP
         }
  ]

testAccountCreation ::
  PR.Context Core.UA
    IO
    ([(Types.Transaction, Types.ValidResult)],
     [(Types.Transaction, Types.FailureKind)],
     [Maybe Types.Account],
     Types.Account,
     Types.BankStatus)
testAccountCreation = do
    transactions <- processTransactions transactionsInput
    let ((suc, fails), state) = Types.runSI (Sch.filterTransactions transactions)
                                            Types.dummyChainMeta
                                            initialBlockState
    let accounts = state ^. blockAccounts
    let accAddrs = map accountAddressFromCred [cdi1,cdi2,cdi3,cdi8,cdi6]
    case invariantBlockState state of
        Left f -> liftIO $ assertFailure $ f ++ "\n" ++ show state
        _ -> return ()
    return (suc, fails, map (\addr -> accounts ^? ix addr) accAddrs, accounts ^. singular (ix alesAccount), state ^. blockBank)

checkAccountCreationResult ::
  ([(Types.Transaction, Types.ValidResult)],
   [(Types.Transaction, Types.FailureKind)],
   [Maybe Types.Account],
   Types.Account,
   Types.BankStatus)
  -> Bool
checkAccountCreationResult (suc, fails, stateAccs, stateAles, bankState) =
  null fails && -- all transactions succeed, but some are rejected
  txsuc &&
  txstateAccs &&
  stateInvariant
  where txsuc = case suc of
          (_, a11) : (_, a12) : (_, a13) : (_, a14) : (_, a15) : (_, a16) : (_, a17) : [] |
            Types.TxSuccess [Types.AccountCreated _, Types.CredentialDeployed _] <- a11,
            Types.TxSuccess [Types.AccountCreated _, Types.CredentialDeployed _] <- a12,
            Types.TxSuccess [Types.AccountCreated _, Types.CredentialDeployed _] <- a13,
            Types.TxReject (Types.DuplicateAccountRegistrationID _) <- a14,
            Types.TxSuccess [Types.AccountCreated _, Types.CredentialDeployed _] <- a15,
            Types.TxSuccess [Types.CredentialDeployed _] <- a16,
            Types.TxReject Types.OutOfEnergy <- a17 -> True
          _ -> False
        txstateAccs = case stateAccs of
                        [Just _, Just _, Just _, Nothing, Just _] -> True -- account 13 was not created because of duplicate registration id
                        _ -> False
        stateInvariant = stateAles ^. Types.accountAmount + bankState ^. Types.executionCost == initialAmount

tests :: SpecWith ()
tests = 
  describe "Account creation" $ do
    specify "3 accounts created, fourth rejected, one more created, a credential deployed, and out of gas " $ do
      PR.evalContext Init.initialContextData testAccountCreation `shouldReturnP` checkAccountCreationResult
