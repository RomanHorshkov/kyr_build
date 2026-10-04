#!/usr/bin/env bash
# build_fuzz.sh — every KYR_FUZZ_TARGETS harness as build/fuzz/<target>, libFuzzer when clang has it, else the standalone driver (kyr-build lib/test.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${KYR_BUILD_DIR}/lib/kyr.sh"
kyr_fuzz_build
