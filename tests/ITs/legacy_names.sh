#!/usr/bin/env bash
# The legacy-names gate from the built deb (check_legacy_names.sh, legacy_names.pat): its own files pass it; a name for each
# pattern line, planted in a new file, is refused at its line; history and line entries fence what they name and nothing more;
# an entry that fences nothing and a malformed entry are refused; a kyr-build wrapper is kyr_build's text while it equals the
# pinned one, the repository's once changed by hand; a binary file is not read. The names are spelled in two pieces here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
KB="${SCRATCH}/kb/usr/local/share/kyr-build"
CHECK="${KB}/check_legacy_names.sh"
[[ -x "${CHECK}" && -f "${KB}/legacy_names.pat" ]] || fail "kyr-build lacks check_legacy_names.sh or legacy_names.pat"

# One name per pattern line, in the file's order.
SAMPLES=("D""B_server" "D""B_APP_DB_ROOT" "D""B_BACKEND" "lib""db-jose-dev" "d""b-http" "H""S_DOMAIN" "h""s_device" "h""s-managed"
    "HSFront""End" "home""server" "RMS""_app" "RomanHorshkov/""Utils" "Upstream-Name: ""Utils" "cd ../""DB" "NGINX_""API_RATE"
    "SYSMON_""PERIOD_S" "RH_DEPS""_CACHE" "/srv/""db" ".d""b_app.lock" "LEGACY_""TREES" "E2E_D""B_EDITION" "platform ""DB")
mapfile -t PATS < <(grep -vE '^[[:space:]]*(#|$)' "${KB}/legacy_names.pat")
(( ${#PATS[@]} == ${#SAMPLES[@]} )) || fail "${#PATS[@]} pattern lines, ${#SAMPLES[@]} samples"
for i in "${!PATS[@]}"; do grep -qP -- "${PATS[i]}" <<< "${SAMPLES[i]}" || fail "the sample for pattern line $((i + 1)) does not match it"; done

R="${SCRATCH}/repo"; mkdir -p "${R}"
( cd "${R}" && git init -q -b master && printf '# r\n\nclean text\n' > README.md && git add -A )
run() { KYR_BUILD_DIR="${2:-${KB}}" "${CHECK}" "${R}" > "${SCRATCH}/out" 2>&1; local rc=$?; cat "${SCRATCH}/out"; return "${rc}"; }
refused() { # <what> <text the output must hold> [kyr-build dir]
    local out rc=0; out="$(run "" "${3:-}")" || rc=$?
    (( rc == 1 )) || { printf '%s\n' "${out}" >&2; fail "accepted (exit ${rc}): $1"; }
    grep -qF -- "$2" <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "refused without \"$2\": $1"; }
}
passes() { run "" "${2:-}" > /dev/null || { cat "${SCRATCH}/out" >&2; fail "refused: $1"; }; }

passes "a clean repository"
mkdir -p "${R}/gate" && cp "${KB}/check_legacy_names.sh" "${KB}/legacy_names.pat" "${R}/gate/" && git -C "${R}" add -A
passes "the gate's own files"

for i in "${!SAMPLES[@]}"; do
    printf 'first line\nsee %s here\n' "${SAMPLES[i]}" > "${R}/planted.txt"
    refused "pattern line $((i + 1)) planted in a new file" "planted.txt:2:"
done
rm -f "${R}/planted.txt"

printf 'record: %s\n' "${SAMPLES[0]}" > "${R}/RECORD.md"
printf 'History: 1.0 was %s.\nlive %s\n' "${SAMPLES[10]}" "${SAMPLES[5]}" > "${R}/NOTES.md"
printf '# kept history\nhistory RECORD.md\nline NOTES.md History: 1.0 was %s.\n' "${SAMPLES[10]}" > "${R}/legacy_names.allow"
git -C "${R}" add -A
refused "a live name beside a fenced sentence" "NOTES.md:2:"
grep -qE 'RECORD\.md|NOTES\.md:1:' "${SCRATCH}/out" && fail "a fenced record or sentence was reported"
printf 'History: 1.0 was %s.\nlive text\n' "${SAMPLES[10]}" > "${R}/NOTES.md"
passes "a history file and a fenced sentence"
printf 'History: 1.0 was %s. Next %s\n' "${SAMPLES[10]}" "${SAMPLES[6]}" > "${R}/NOTES.md"
refused "a second name on a fenced sentence's line" "NOTES.md:1:"
printf 'History: 1.0 was %s.\n' "${SAMPLES[10]}" > "${R}/NOTES.md"

cp "${R}/legacy_names.allow" "${SCRATCH}/allow"
printf 'history GONE.md\n' >> "${R}/legacy_names.allow"
refused "a history entry that fences nothing" "history GONE.md fences nothing"
cp "${SCRATCH}/allow" "${R}/legacy_names.allow"; printf 'line NOTES.md a sentence not there\n' >> "${R}/legacy_names.allow"
refused "a line entry that fences nothing" "line NOTES.md a sentence not there fences nothing"
cp "${SCRATCH}/allow" "${R}/legacy_names.allow"; printf 'keep NOTES.md\n' >> "${R}/legacy_names.allow"
refused "a malformed entry" "legacy_names.allow:4:"
cp "${SCRATCH}/allow" "${R}/legacy_names.allow"
passes "the allow list restored"

cp -a "${KB}" "${SCRATCH}/kb2"; printf '# %s\n' "${SAMPLES[16]}" >> "${SCRATCH}/kb2/wrappers/deps.sh"
mkdir -p "${R}/utils" && cp "${SCRATCH}/kb2/wrappers/deps.sh" "${R}/utils/deps.sh" && git -C "${R}" add -A
passes "a kyr-build wrapper equal to the pinned one" "${SCRATCH}/kb2"
printf '\n' >> "${R}/utils/deps.sh"
refused "a kyr-build wrapper changed by hand" "utils/deps.sh:" "${SCRATCH}/kb2"
rm -rf "${R}/utils"

printf '\0%s\0' "${SAMPLES[0]}" > "${R}/blob.bin" && git -C "${R}" add -A
passes "a binary file"
