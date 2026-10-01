#!/usr/bin/env bash
# 
# Build and run the pure-C SIMD search test suite.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

workdir="$(mktemp -d -t 'thread-utils-simd-test.XXXXXX')"
trap 'rm -rf "$workdir"' EXIT

ghc -O2 -Wall -no-hs-main -outputdir "$workdir" \
    simd_search_test.c -o "$workdir/simd_search_test"

exec "$workdir/simd_search_test"
