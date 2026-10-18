#!/usr/bin/env bash
# The warnings stage from the built deb (check_warnings.sh): real diagnostics of tools that do not stop on -Werror are refused
# (a gcc #warning built outside the profile, a linker warning, a driver warning), runtime "WARNING:" lines and a clean log pass;
# and a template repository whose build hook compiles outside the profile ends its pipeline FAILED at the warnings stage alone.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
CHECK="${SCRATCH}/kb/usr/local/share/kyr-build/check_warnings.sh"
[[ -x "${CHECK}" ]] || fail "kyr-build lacks check_warnings.sh"
L="${SCRATCH}/logs"; W="${SCRATCH}/w"; mkdir -p "${L}" "${W}"

printf 'int ok(void);\nint ok(void) { return 0; }\n' > "${W}/clean.c"
gcc -std=c11 -Wall -Werror -c "${W}/clean.c" -o "${W}/clean.o" > "${L}/build_release.log" 2>&1
printf '==1==WARNING: ASan is ignoring requested __asan_handle_no_return\nWARNING: Failed to find function "x".\n[ RUN      ] the warning: test\n' \
    > "${L}/tests_sanitize.log"
"${CHECK}" "${L}" > "${SCRATCH}/out" 2>&1 || { cat "${SCRATCH}/out" >&2; fail "a clean build log and runtime WARNING lines were refused"; }

printf '#warning planted outside the profile\nint p(void);\nint p(void) { return 1; }\n' > "${W}/planted.c"
gcc -std=c11 -c "${W}/planted.c" -o "${W}/planted.o" > "${L}/hook_shim.log" 2>&1
"${CHECK}" "${L}" > "${SCRATCH}/out" 2>&1 && fail "a gcc #warning passed"
grep -qF 'hook_shim.log:1:' "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "the #warning is not named"; }
rm -f "${L}/hook_shim.log"

printf '.text\n.globl stack_fn\nstack_fn:\n\tret\n' > "${W}/noexec.s"
gcc -c "${W}/noexec.s" -o "${W}/noexec.o"
gcc -shared -o "${W}/libnoexec.so" "${W}/noexec.o" > "${L}/link.log" 2>&1 || true
if grep -q 'warning:' "${L}/link.log"; then
    "${CHECK}" "${L}" > "${SCRATCH}/out" 2>&1 && fail "a linker warning passed"
    grep -qF 'link.log:' "${SCRATCH}/out" || fail "the linker warning is not named"
fi
rm -f "${L}/link.log"
gcc -std=c11 -c "${W}/clean.c" -o "${W}/x.o" "${W}/clean.o" > "${L}/driver.log" 2>&1 || true
"${CHECK}" "${L}" > "${SCRATCH}/out" 2>&1 && fail "a driver warning passed"
grep -qF 'driver.log:' "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "the driver warning is not named"; }
rm -f "${L}/driver.log"
printf 'warnings.log is this stage'"'"'s own: x.c:1:1: warning: never read\n' > "${L}/warnings.log"
"${CHECK}" "${L}" > /dev/null 2>&1 || fail "the stage read its own log"

# The pipeline: a build hook compiling outside the profile is the one red stage.
A="${SCRATCH}/kyr_zwarn"; instantiate "${A}"
cat >> "${A}/utils/kyr_word_project.sh" <<'EOF'
KYR_PIPELINE_PROFILES=(release)
KYR_TEST_PROFILES=(release)
KYR_PIPELINE_EXTRA=("build|shim|printf '#warning outside the profile\nint s(void);\nint s(void) { return 0; }\n' > build/shim.c && \${CC:-gcc} -std=c11 -c build/shim.c -o build/shim.o")
EOF
( cd "${A}" && git add -A && git -c user.name=it -c user.email=it@localhost commit -q -m shim )
rc=0; ( cd "${A}" && ./utils/run_pipeline.sh ) > "${SCRATCH}/pipeline.log" 2>&1 || rc=$?
(( rc == 1 )) || { tail -n 40 "${SCRATCH}/pipeline.log" >&2; fail "the pipeline did not fail (exit ${rc})"; }
grep -q '^   FAIL warnings$' "${SCRATCH}/pipeline.log" || { tail -n 40 "${SCRATCH}/pipeline.log" >&2; fail "no FAIL warnings in the summary"; }
grep -q '^   ok   shim$' "${SCRATCH}/pipeline.log" || fail "the hook itself did not pass (the warning must be the only failure)"
[[ "$(grep -c '^   FAIL [^(]' "${SCRATCH}/pipeline.log")" == 1 ]] || { grep '^   FAIL [^(]' "${SCRATCH}/pipeline.log" >&2; fail "another stage failed"; }
grep -qF 'shim.log:' "${A}/build/pipeline/warnings.log" || fail "the warnings stage does not name the hook's log"
