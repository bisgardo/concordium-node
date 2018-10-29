#!/bin/sh
git clone https://github.com/mitls/hacl-c
( cd hacl-c && make && cp libhacl.so /usr/lib );
rm -rf hacl-c

curl -sSL https://get.haskellstack.org/ | sh
( cd consensus/Concordium && stack build --ghc-options '-dynamic' &&
  cp .stack-work/install/x86_64-linux-tinfo6/lts-12.10/8.4.3/lib/x86_64-linux-ghc-8.4.3/libHSConcordium-0.1.0.0-2r8nwUTORL78ALUQnjpzij-ghc8.4.3.so /usr/local/lib ) 
find ~/.stack/programs -name \*HSrts-ghc8.4.3.so -exec cp {} /usr/local/lib \;

git clone https://github.com/KDE/heaptrack.git
(cd heaptrack && patch src/track/heaptrack.sh.cmake ../scripts/include-date-in-name.patch && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=release .. && make -j$(nproc) && make install);
rm -rf heaptrack

ldconfig
rustup default nightly-2018-10-26

