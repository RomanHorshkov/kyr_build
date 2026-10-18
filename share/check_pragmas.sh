#!/usr/bin/env bash
# check_pragmas.sh [repo-root] — refuse a diagnostic off-switch in the repository's text files (the tracked ones and the new
# unignored ones, git ls-files; never build output, never app/extern, whose bytes vendor.sh pins to upstream). One line per hit,
# "<path>:<line>: <rule>: <text>", then "pragmas: none" or "pragmas: found" (exit 1). The rules:
#
#   pragma-off       a GCC or clang diagnostic pragma that turns a diagnostic off or back into a warning ("ignored", "warning")
#   system-header    the GCC system_header pragma (every warning of the rest of the file off)
#   wno              a -Wno-<name> option, anywhere (a project file, a script, a source)
#   w-flag           a bare -w in a utils/*_project.sh declaration (every warning off)
#   unused-attr      the unused attribute, GNU or C23 spelling (a parameter or variable kept quiet instead of removed or used)
#   extension        the GNU extension keyword (-Wpedantic off for one expression)
#
#   pragmas.allow   at the root, one reviewed entry per kept site, '#' comments: "<path> | <text> | <reason>": every hit in <path>
#                   whose line holds <text> is kept; the reason is required; an entry that keeps nothing fails
#   kyr-build's wrappers in utils/, byte-identical to the pinned kyr-build's (the template stage proves it), are kyr_build's text.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${1:-${ROOT_DIR:-$(pwd -P)}}" && pwd -P)"
ALLOW_FILE="${ROOT_DIR}/pragmas.allow"
KB="${KYR_BUILD_DIR:-}"; [[ -d "${KB}/wrappers" ]] || KB="${SCRIPT_DIR}"; [[ -d "${KB}/wrappers" ]] || KB="${ROOT_DIR}/build/sysroot/share/kyr-build"
die() { printf 'check_pragmas: %s\n' "$*" >&2; exit 2; }
git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree > /dev/null 2>&1 || die "${ROOT_DIR} is not a git work tree"

# Each rule's PCRE, spelled so that this file does not match it.
P='pragma'; D='diagnostic'
RULES=(pragma-off system-header wno w-flag unused-attr extension)
RE_pragma_off="#[[:space:]]*${P}[[:space:]]+(GCC|clang)[[:space:]]+${D}[[:space:]]+(ignored|warning)\\b"
RE_system_header="#[[:space:]]*${P}[[:space:]]+GCC[[:space:]]+system""_header\\b"
RE_wno="(?<![A-Za-z0-9_-])-W""no-[A-Za-z]"
RE_w_flag="(?<![A-Za-z0-9_-])-w(?![A-Za-z0-9_=-])"
RE_unused_attr="__attribute__[[:space:]]*\\(\\((?:[^()]|\\([^()]*\\))*\\b(__)?un""used(__)?\\b|\\[\\[[[:space:]]*(gnu::)?(maybe_un""used|un""used)[[:space:]]*\\]\\]"
RE_extension="\\b__ext""ension__\\b"
ANY="$(for r in "${RULES[@]}"; do v="RE_${r//-/_}"; printf '(?:%s)|' "${!v}"; done)"; ANY="${ANY%|}"
printf '' | grep -P -- "${ANY}" > /dev/null; (( $? < 2 )) || die "grep -P refuses the rules"

declare -A USED=()
A_PATH=(); A_TEXT=(); A_KEY=()
rc=0
if [[ -f "${ALLOW_FILE}" ]]; then
    n=0
    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        n=$((n + 1)); [[ "${raw}" =~ ^[[:space:]]*(#|$) ]] && continue
        IFS='|' read -r path text reason extra <<< "${raw}"
        path="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "${path}")"
        text="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "${text}")"
        reason="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "${reason}")"
        if [[ -z "${path}" || -z "${text}" || -z "${reason}" || -n "${extra}" ]]; then
            printf '  BAD     pragmas.allow:%s: an entry is "<path> | <text> | <reason>", the reason required\n' "${n}"; rc=1; continue
        fi
        A_PATH+=("${path}"); A_TEXT+=("${text}"); A_KEY+=("pragmas.allow:${n}: ${path} | ${text}")
    done < "${ALLOW_FILE}"
fi

kyr_build_wrapper() { [[ "$1" == utils/* && "$1" != utils/*/* && -f "${KB}/wrappers/${1#utils/}" ]] && cmp -s "${KB}/wrappers/${1#utils/}" "${ROOT_DIR}/$1"; }
rule_of() {  # <path> <text>: the first rule the line breaks, empty when none
    local r v
    for r in "${RULES[@]}"; do
        v="RE_${r//-/_}"
        [[ "${r}" == w-flag && ! "$1" =~ ^utils/[^/]+_project\.sh$ ]] && continue
        printf '%s\n' "$2" | grep -qP -- "${!v}" && { printf '%s\n' "${r}"; return; }
    done
}

hits=0
while IFS= read -r -d '' path && IFS= read -r line; do
    lineno="${line%%:*}"; text="${line#*:}"
    [[ "${path}" == pragmas.allow ]] && continue
    kyr_build_wrapper "${path}" && continue
    rule="$(rule_of "${path}" "${text}")"
    [[ -n "${rule}" ]] || continue
    kept=0
    for i in "${!A_PATH[@]}"; do
        [[ "${A_PATH[i]}" == "${path}" && "${text}" == *"${A_TEXT[i]}"* ]] || continue
        kept=1; USED["${A_KEY[i]}"]=1
    done
    (( kept )) && continue
    printf '  %s:%s: %s: %s\n' "${path}" "${lineno}" "${rule}" "$(printf '%s' "${text}" | sed 's/^[[:space:]]*//' | cut -c1-160)"
    hits=$((hits + 1))
done < <(cd "${ROOT_DIR}" && { git ls-files -z; git ls-files -z --others --exclude-standard; } | sort -zu |
    while IFS= read -r -d '' f; do [[ -f "${f}" && ! -L "${f}" && "${f}" != app/extern/* ]] && printf '%s\0' "${f}"; done |
    xargs -0 -r grep -IPnHZ -- "${ANY}")

for key in "${A_KEY[@]}"; do
    [[ -n "${USED[${key}]+x}" ]] || { printf '  STALE   %s keeps nothing\n' "${key}"; rc=1; }
done
(( hits )) && rc=1
(( rc == 0 )) && printf 'pragmas: none\n' || printf 'pragmas: found (%s lines)\n' "${hits}"
exit "${rc}"
