#!/usr/bin/env bash
# buildinfo.sh <deb> [profile] — print the build environment record for one deb (plan 4.1, Debian .buildinfo shaped).
# lib/deb.sh writes it next to every deb as <deb>.buildinfo. Fields: the deb and its hash, SOURCE_DATE_EPOCH, the
# build root's identity (Build-Root: from /etc/kyr-build-root inside build_root.sh enter; none on the host), the commit,
# the profile flags, every tool version and every pinned dependency. Nothing in it is a wall-clock time.
set -euo pipefail
DEB="${1:-}"; PROFILE="${2:-release}"
[[ -f "${DEB}" ]] || { printf 'usage: buildinfo.sh <deb> [profile]\n' >&2; exit 3; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"

# The first line, whatever the exit status; absent when there is none. Read whole: a pipe into head SIGPIPEs a tool still writing.
tool_version() { local out; out="$("$@" 2>/dev/null)" || true; if [[ -n "${out}" ]]; then printf '%s\n' "${out%%$'\n'*}"; else printf 'absent\n'; fi; }
field() { dpkg-deb -f "${DEB}" "$1" 2>/dev/null || true; }

# shellcheck source=lib/root.sh
source "${SCRIPT_DIR}/lib/root.sh"
ROOT_HASH="$(kyr_root_identity || true)"
COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || true)"

printf 'Format: kyr-buildinfo/1\n'
printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$(field Package)" "$(field Version)" "$(field Architecture)"
printf 'Deb: %s\nDeb-Sha256: %s\n' "$(basename "${DEB}")" "$(sha256sum "${DEB}" | awk '{print $1}')"
printf 'Source-Date-Epoch: %s\n' "${SOURCE_DATE_EPOCH:-unset}"
printf 'Build-Root: %s\n' "${ROOT_HASH:-none}"
printf 'Git-Commit: %s\n' "${COMMIT:-none}"
printf 'Kyr-Build: %s\n' "$( [[ -f "${SCRIPT_DIR}/VERSION" ]] && tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION" || printf 'in-tree')"
printf 'Profile: %s\n' "${PROFILE}"
printf 'CPPFLAGS: %s\n' "$(cd "${ROOT_DIR}" && bash "${SCRIPT_DIR}/gcc_build_profiles.sh" print-cppflags "${PROFILE}")"
printf 'CFLAGS: %s\n' "$(cd "${ROOT_DIR}" && bash "${SCRIPT_DIR}/gcc_build_profiles.sh" print-cflags "${PROFILE}")"
printf 'LDFLAGS: %s\n' "$(cd "${ROOT_DIR}" && bash "${SCRIPT_DIR}/gcc_build_profiles.sh" print-ldflags "${PROFILE}")"
printf 'Tools:\n'
printf ' gcc: %s\n' "$(tool_version "${CC:-gcc}" --version)"
printf ' ld: %s\n' "$(tool_version ld --version)"
printf ' ar: %s\n' "$(tool_version ar --version)"
printf ' dpkg-deb: %s\n' "$(tool_version dpkg-deb --version)"
printf ' tar: %s\n' "$(tool_version tar --version)"
printf ' gzip: %s\n' "$(tool_version gzip --version)"
printf ' libc: %s\n' "$(tool_version ldd --version)"
printf 'Host-Architecture: %s\n' "$(dpkg --print-architecture)"
if [[ -f "${ROOT_DIR}/deps.txt" ]]; then
    printf 'Dependencies:\n'
    awk '$1=="own"{printf " %s %s %s\n", $2, $3, ($5 ~ /^[0-9a-f]{64}$/ ? $5 : "-")} $1=="apt"{printf " apt %s %s\n", $2, ($3 != "" ? $3 : "-")}' "${ROOT_DIR}/deps.txt"
fi
