#!/usr/bin/env bash
# run_benchmarks.sh — builds and runs every KYR_STRESS_SUITES benchmark, summary under tests/results/stress (kyr-build lib/test.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${KYR_BUILD_DIR}/lib/kyr.sh"
kyr_stress_build && kyr_stress_run
