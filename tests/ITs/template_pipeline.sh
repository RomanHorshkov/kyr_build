#!/usr/bin/env bash
# The shipped template is a green repository out of the box, as a new product kyr-build has never heard of: wrappers reach
# the sysroot copies, the pipeline passes (tier stage included), and the same commit built in two different directories
# gives byte-identical debs (prefix maps, epoch, umask).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
A="${SCRATCH}/a/kyr_zeta"; B="${SCRATCH}/b/kyr_zeta"
instantiate "${A}"; instantiate "${B}"
cd "${A}"
./utils/deps.sh sysroot > /dev/null
has "-ffile-prefix-map=${A}=\." ./utils/gcc_build_profiles.sh print-cflags release || fail "wrapper CLI"
rc=0; ./utils/check_hardening.sh > /dev/null 2>&1 || rc=$?; [[ "${rc}" == 3 ]] || fail "check_hardening wrapper (exit ${rc})"
bash -c 'source ./utils/gcc_build_profiles.sh && [[ -n "${CFLAGS_RELEASE[*]}" && "${KYR_BUILD_DIR}" == */build/sysroot/share/kyr-build ]]' || fail "wrapper source"
./utils/run_pipeline.sh > "${SCRATCH}/pipeline.log" 2>&1 || { tail -40 "${SCRATCH}/pipeline.log"; fail "template pipeline"; }
grep -q 'pipeline GREEN' "${SCRATCH}/pipeline.log" || fail "pipeline not green"
epoch="$(git log -1 --format=%ct)"
cd "${B}"
./utils/deps.sh sysroot > /dev/null
SOURCE_DATE_EPOCH="${epoch}" ./utils/build_deb.sh > /dev/null
diff <(sed 's| .*/| |' "${A}/build/debs/SHA256SUMS") <(sed 's| .*/| |' "${B}/build/debs/SHA256SUMS") || fail "debs differ between two build directories"
has "${SCRATCH}" strings "${B}/build/release/libkyr_word.so.0.1.0" && fail "build path leaked into the shared object"
root_id="$(bash -c 'source "$1/share/lib/root.sh" && kyr_root_identity || printf none' _ "${ROOT_DIR}")"
grep -q "^Build-Root: ${root_id}$" "${B}"/build/debs/libkyr-word_0.1.0_*.deb.buildinfo || fail "buildinfo without the build root's identity (${root_id})"
