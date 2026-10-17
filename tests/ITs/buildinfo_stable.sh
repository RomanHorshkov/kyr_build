#!/usr/bin/env bash
# buildinfo.sh from the built deb records a tool's first version line and nothing else, whatever the tool does after it: a gcc
# that keeps writing after a pause (its reader has its line and is gone: SIGPIPE under pipefail), an ar that fails after its
# line and a tool that is not installed give the same bytes run after run, never a stray "absent" line.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
KB="${SCRATCH}/kb/usr/local/share/kyr-build"
BIN="${SCRATCH}/bin"; mkdir -p "${BIN}"
cat > "${BIN}/fake-cc" <<'TOOL'
#!/usr/bin/env bash
printf 'fake-cc 1.2.3\n'
sleep 0.3
for i in $(seq 1 4000); do printf 'more version text %s\n' "${i}"; done
TOOL
cat > "${BIN}/ar" <<'TOOL'
#!/usr/bin/env bash
printf 'fake-ar 9\nsecond line\n'
exit 3
TOOL
chmod +x "${BIN}/fake-cc" "${BIN}/ar"
R="${SCRATCH}/repo"; mkdir -p "${R}"
( cd "${R}" && git init -q -b master && printf 'x\n' > f && git add -A && git -c user.name=it -c user.email=it@localhost commit -q -m init )
info() { ( cd "${R}" && PATH="${BIN}:${PATH}" CC="$1" ROOT_DIR="${R}" SOURCE_DATE_EPOCH=1 bash "${KB}/buildinfo.sh" "${KYR_DEB}" ); }
info fake-cc > "${SCRATCH}/a"
info fake-cc > "${SCRATCH}/b"
cmp "${SCRATCH}/a" "${SCRATCH}/b" || { diff "${SCRATCH}/a" "${SCRATCH}/b" >&2 || true; fail "two runs differ"; }
grep -qx ' gcc: fake-cc 1.2.3' "${SCRATCH}/a" || fail "the gcc line is not the tool's first line"
grep -qx ' ar: fake-ar 9' "${SCRATCH}/a" || fail "the ar line is not the failing tool's first line"
if grep -qx 'absent' "${SCRATCH}/a"; then sed -n '/^Tools:/,/^Host/p' "${SCRATCH}/a" >&2; fail "a stray absent line"; fi
info no-such-compiler-kyr > "${SCRATCH}/c"
grep -qx ' gcc: absent' "${SCRATCH}/c" || fail "a missing tool is not recorded as absent"
