#!/usr/bin/env bash
# check_abi.sh [--update | --exports [lib.so]] — the public ABI gate, SemVer on the ABI (lifted from DB_lmdb's
# utils/check_abi_layout.sh). Runs in the repository at ROOT_DIR through its utils/check_abi.sh wrapper; the pipeline runs it when
# abi/layout.txt exists.
#
#   abi/layout.txt   the committed ABI: the data model; every public scalar type's size; every public struct's size, alignment and
#                    each member's offset and size (bit-fields by bit offset and width), and every member written as a function pointer with
#                    its full signature (`  signature <member> <type>`); every public enum's enumerator values;
#                    every public callback's signature; every function the public headers declare (return type, parameter types);
#                    every numeric <CONST_PREFIX>* #define; every enumerator of an unnamed public enum. A `major` line records
#                    VERSION's major.
#   abi/layout.c     optional: a hand-written layout program (DB_lmdb's form), cross-checked against the debug information. Without
#                    it the program is generated from the public headers, so every public struct and member is covered by
#                    construction and moving a declaration inside a header changes nothing.
#
# The rule, against the last release (the newest tag v<x.y.z> reachable; without one, the previous commit):
#   an existing line changed or removed, or a member added to an existing struct   needs a raised MAJOR
#   new names in categories the file already covers, or a *_ABI_MINOR that only rose needs a raised MINOR (or MAJOR)
#   only lines of categories the file did not cover (a gate that learned more)     needs nothing (a tooling change)
# Applied by --update, to the working tree and to every commit that changed abi/layout.txt.
#
# What is public comes from utils/<name>_project.sh (defaults from the template's variables, each overridable):
#   KYR_ABI_NAME          header text                    KYR_LIB
#   KYR_ABI_TYPE_PREFIX   public typedefs                "${KYR_LIB}_"
#   KYR_ABI_FUNC_PREFIX   public functions               "${KYR_LIB}_"
#   KYR_ABI_CONST_PREFIX  public numeric #defines        KYR_LIB in upper case, then "_"
#                         each of the three a list (space-separated string or bash array) for a library with several namespaces
#   KYR_ABI_NODE          linker version node prefix     KYR_LIB in upper case (the map's node is <NODE>_<major>)
#   KYR_ABI_INCLUDE_DIR   public header root             app/include
#   KYR_ABI_UMBRELLA      one header including all       unset: KYR_ABI_HEADERS, else every *.h under <root>/${KYR_INCLUDE_ROOT}
#   KYR_ABI_HEADERS       public headers (array, relative to the root)
#   KYR_LIB_CPPFLAGS      include flags (the sysroot's headers for what the public headers include)
# DB_lmdb's eight variables map one to one (NAME TYPE_PREFIX FUNC_PREFIX CONST_PREFIX NODE INCLUDE_DIR UMBRELLA, the layout path is
# fixed). Differences from its gate: without abi/layout.c the program is generated; enumerators of unnamed enums are covered
# (`enumerator` lines, a category of their own); --exports compares functions only, so a module may export its descriptor object;
# the header comment line is kept as committed and comment lines are not ABI.
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd -- "${ROOT_DIR}"
die() { printf 'check_abi: %s\n' "$*" >&2; exit 1; }
LAYOUT="abi/layout.txt"
OUT="build/abi"
PY=(python3 "${SCRIPT_DIR}/abi.py")

MODE=check SO=""
case "${1:-}" in
    "") ;;
    --update) MODE=update ;;
    --exports) MODE=exports; SO="${2:-}" ;;
    *) die "unknown argument '$1' (--update | --exports [lib.so])" ;;
esac

# The project's declarations; the catalog first, because a project file may call its helpers.
if [[ -f utils/gcc_build_profiles.sh ]]; then
    # shellcheck source=/dev/null
    source utils/gcc_build_profiles.sh
fi
projects=(utils/*_project.sh)
[[ -f "${projects[0]}" ]] || die "no utils/<name>_project.sh: nothing says what the public ABI is"
# shellcheck source=/dev/null
source "${projects[0]}"
LIB="${KYR_LIB:-}"
UPPER="$(tr '[:lower:]-' '[:upper:]_' <<< "${LIB}")"
NAME="${KYR_ABI_NAME:-${LIB}}"
# prefixes <var> <default>: a space-separated list from a string or an array
prefixes() {
    local -n v="$1"
    if declare -p "$1" 2> /dev/null | grep -q '^declare -a'; then printf '%s\n' "${v[*]}"; else printf '%s\n' "${v:-$2}"; fi
}
TYPE_PREFIX="$(prefixes KYR_ABI_TYPE_PREFIX "${LIB:+${LIB}_}")"
FUNC_PREFIX="$(prefixes KYR_ABI_FUNC_PREFIX "${LIB:+${LIB}_}")"
CONST_PREFIX="$(prefixes KYR_ABI_CONST_PREFIX "${UPPER:+${UPPER}_}")"
NODE="${KYR_ABI_NODE:-${UPPER}}"
[[ -n "${TYPE_PREFIX}" && -n "${FUNC_PREFIX}" && -n "${CONST_PREFIX}" && -n "${NODE}" ]] || die "KYR_LIB (or every KYR_ABI_*) must be set in ${projects[0]}"
INCLUDE_DIR="${KYR_ABI_INCLUDE_DIR:-app/include}"
if [[ -n "${KYR_ABI_UMBRELLA:-}" ]]; then
    HEADERS=("${KYR_ABI_UMBRELLA}")
elif declare -p KYR_ABI_HEADERS > /dev/null 2>&1; then
    HEADERS=("${KYR_ABI_HEADERS[@]}")
else
    mapfile -t HEADERS < <(cd "${INCLUDE_DIR}" && find "${KYR_INCLUDE_ROOT:-.}" -name '*.h' | sed 's|^\./||' | LC_ALL=C sort)
fi
(( ${#HEADERS[@]} )) || die "no public header under ${INCLUDE_DIR}/${KYR_INCLUDE_ROOT:-}"
CPPFLAGS_ABI=(-std=c11 -D_DEFAULT_SOURCE -I"${INCLUDE_DIR}")
declare -p KYR_LIB_CPPFLAGS > /dev/null 2>&1 && CPPFLAGS_ABI+=("${KYR_LIB_CPPFLAGS[@]}")

VERSION_NOW="$(tr -d '[:space:]' < VERSION)"
[[ "${VERSION_NOW}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '${VERSION_NOW}' is not MAJOR.MINOR.PATCH"
MAJOR="${VERSION_NOW%%.*}"
mkdir -p "${OUT}"

if [[ "${MODE}" == exports ]]; then
    [[ -f "${LAYOUT}" ]] || die "missing ${LAYOUT}"
    SO="${SO:-build/release/lib${LIB}.so}"
    [[ -f "${SO}" ]] || die "--exports needs the built shared library (${SO})"
    exported="$(readelf --dyn-syms -W "${SO}" | awk '$1 ~ /^[0-9]+:$/ && $7 != "UND" && $7 != "ABS" && $5 != "LOCAL" && $4 == "FUNC" {print $8}' | LC_ALL=C sort)"
    declared="$(awk -v node="${NODE}_${MAJOR}" '$1=="function" {print $2 "@@" node}' "${LAYOUT}" | LC_ALL=C sort)"
    if [[ "${exported}" != "${declared}" ]]; then
        diff <(printf '%s\n' "${declared}") <(printf '%s\n' "${exported}") | sed -n 's/^< /  declared, not exported: /p; s/^> /  exported, not declared: /p'
        die "${SO##*/} must export exactly the functions ${INCLUDE_DIR} declares, each as <name>@@${NODE}_${MAJOR}"
    fi
    printf 'check_abi: %s exports exactly the %d declared functions, all @@%s_%s\n' "${SO##*/}" "$(grep -c . <<< "${declared}")" "${NODE}" "${MAJOR}"
    exit 0
fi

# The public headers, compiled once for their debug information and their declarations.
{
    for h in "${HEADERS[@]}"; do printf '#include <%s>\n' "${h}"; done
    printf 'int main(void)\n{\n    return 0;\n}\n'
} > "${OUT}/headers.c"
"${CC:-gcc}" "${CPPFLAGS_ABI[@]}" -g -O0 -fno-eliminate-unused-debug-types -aux-info "${OUT}/headers.aux" "${OUT}/headers.c" \
    -o "${OUT}/headers" || die "the public headers do not compile on their own (above)"
readelf --debug-dump=info "${OUT}/headers" > "${OUT}/headers.dwarf"

if [[ -f abi/layout.c ]]; then
    "${CC:-gcc}" "${CPPFLAGS_ABI[@]}" -g -O0 -fno-eliminate-unused-debug-types -aux-info "${OUT}/layout.aux" abi/layout.c -o "${OUT}/layout"
    "${OUT}/layout" > "${OUT}/layout.program"
    readelf --debug-dump=info "${OUT}/layout" > "${OUT}/layout.dwarf"
    "${PY[@]}" complete "${OUT}/layout.dwarf" "${TYPE_PREFIX}" "${OUT}/layout.program" \
        || die "abi/layout.c does not list every public struct, field and type (above)"
    DWARF="${OUT}/layout.dwarf" AUX="${OUT}/layout.aux"
else
    "${PY[@]}" program "${OUT}/headers.dwarf" "${TYPE_PREFIX}" "${OUT}/layout.c" "${HEADERS[@]}"
    "${CC:-gcc}" "${CPPFLAGS_ABI[@]}" "${OUT}/layout.c" -o "${OUT}/layout" || die "the generated layout program does not compile (above)"
    "${OUT}/layout" > "${OUT}/layout.program"
    DWARF="${OUT}/headers.dwarf" AUX="${OUT}/headers.aux"
fi
"${PY[@]}" sections "${DWARF}" "${AUX}" "${TYPE_PREFIX}" "${FUNC_PREFIX}" "${INCLUDE_DIR}/" > "${OUT}/layout.sections"

# Numeric #define constants: every object-like <CONST_PREFIX>* macro whose value is not a string, evaluated by the compiler.
mapfile -t consts < <("${CC:-gcc}" "${CPPFLAGS_ABI[@]}" -dM -E "${OUT}/headers.c" \
    | awk -v p="^(${CONST_PREFIX// /|})[A-Z0-9_]*$" '$1 == "#define" && $2 ~ p && NF > 2 && $3 !~ /^"/ {print $2}' | LC_ALL=C sort)
{
    printf '#include <stdio.h>\n'
    for h in "${HEADERS[@]}"; do printf '#include <%s>\n' "${h}"; done
    printf 'int main(void)\n{\n'
    for c in "${consts[@]}"; do printf '    printf("constant %%s %%lld\\n", "%s", (long long)(%s));\n' "${c}" "${c}"; done
    printf '    return 0;\n}\n'
} > "${OUT}/constants.c"
"${CC:-gcc}" "${CPPFLAGS_ABI[@]}" "${OUT}/constants.c" -o "${OUT}/constants" || die "a macro with a constant prefix (${CONST_PREFIX}) is not a numeric constant (above)"
"${OUT}/constants" > "${OUT}/layout.constants"
"${PY[@]}" enumerators "${OUT}/headers.dwarf" "${TYPE_PREFIX}" > "${OUT}/layout.enumerators"

{
    if [[ -f "${LAYOUT}" ]] && head -1 "${LAYOUT}" | grep -q '^#'; then
        head -1 "${LAYOUT}"
    else
        printf '# %s public ABI, written by check_abi.sh --update (kyr-build): a changed line needs a major, a new name a minor.\n' "${NAME}"
    fi
    printf 'major %s\n' "${MAJOR}"
    cat "${OUT}/layout.program" "${OUT}/layout.sections" "${OUT}/layout.constants" "${OUT}/layout.enumerators"
} > "${OUT}/layout.txt"

have_history() { git rev-parse --is-inside-work-tree > /dev/null 2>&1 && [[ "$(git rev-parse --is-shallow-repository)" == false ]]; }
# release_base <rev>: the newest release tag reachable from <rev>, else <rev> itself.
release_base() { git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$1" 2> /dev/null || printf '%s\n' "$1"; }
# at <rev> <file>: that file's content at <rev>, empty when absent.
at() { git show "$1:$2" 2> /dev/null || true; }
# needs <old-layout> <old-version> <new-layout> <new-version>: prints the classification; fails when VERSION lacks the raise.
needs() {
    local out kind omaj omin nmaj nmin _
    out="$("${PY[@]}" classify "$1" "$3")"
    kind="${out%%$'\n'*}"
    IFS=. read -r omaj omin _ <<< "$2"
    IFS=. read -r nmaj nmin _ <<< "$4"
    printf '%s\n' "${out}"
    case "${kind}" in
        identical | tooling) return 0 ;;
        minor) (( nmaj > omaj || (nmaj == omaj && nmin > omin) )) ;;
        *) (( nmaj > omaj )) ;;
    esac
}

if [[ "${MODE}" == update ]]; then
    if have_history && git rev-parse -q --verify HEAD > /dev/null; then
        base="$(release_base HEAD)"
        at "${base}" "${LAYOUT}" > "${OUT}/layout.base"
        base_version="$(at "${base}" VERSION | tr -d '[:space:]')"
        if ! verdict="$(needs "${OUT}/layout.base" "${base_version:-0.0.0}" "${OUT}/layout.txt" "${VERSION_NOW}")"; then
            printf '%s\n' "${verdict}"
            die "against ${base:0:12} (VERSION ${base_version}) this change needs a raised ${verdict%%$'\n'*}: raise it in VERSION first"
        fi
    elif [[ -f "${LAYOUT}" && "$(awk '$1=="major" {print $2; exit}' "${LAYOUT}")" == "${MAJOR}" ]]; then
        verdict="$("${PY[@]}" classify "${LAYOUT}" "${OUT}/layout.txt")"
        case "${verdict%%$'\n'*}" in identical | tooling) ;; *) die "no git history: only a major raise or a new category may be written" ;; esac
    fi
    mkdir -p "$(dirname "${LAYOUT}")"
    cp "${OUT}/layout.txt" "${LAYOUT}"
    printf 'check_abi: %s written for %s\n' "${LAYOUT}" "${VERSION_NOW}"
    exit 0
fi

[[ -f "${LAYOUT}" ]] || die "missing ${LAYOUT} (create it with ./utils/check_abi.sh --update)"
if ! cmp -s "${OUT}/layout.txt" "${LAYOUT}"; then
    diff -u "${LAYOUT}" "${OUT}/layout.txt" || true
    recorded="$(awk '$1=="major" {print $2; exit}' "${LAYOUT}")"
    [[ "${recorded}" == "${MAJOR}" ]] \
        || die "VERSION's major is ${MAJOR} but ${LAYOUT} records ${recorded}: run --update in the commit that raises the major"
    verdict="$("${PY[@]}" classify "${LAYOUT}" "${OUT}/layout.txt")"
    case "${verdict%%$'\n'*}" in
        identical) die "only a comment line differs from what the gate writes: run --update" ;;
        tooling) die "the gate now covers new categories: run --update (a tooling change, no raise needed)" ;;
        minor) die "the public API grew (new names, or a raised *_ABI_MINOR): raise VERSION's minor against the last release, then --update" ;;
        *) die "the public ABI changed without a major bump: raise VERSION's major, then --update" ;;
    esac
fi

if have_history; then
    if git rev-parse -q --verify HEAD > /dev/null; then
        base="$(release_base HEAD)"
        at "${base}" "${LAYOUT}" > "${OUT}/layout.base"
        base_version="$(at "${base}" VERSION | tr -d '[:space:]')"
        verdict="$(needs "${OUT}/layout.base" "${base_version:-0.0.0}" "${LAYOUT}" "${VERSION_NOW}")" \
            || die "${LAYOUT} against ${base:0:12} (VERSION ${base_version}) needs a raised ${verdict%%$'\n'*}, VERSION is ${VERSION_NOW}: ${verdict#*$'\n'}"
    fi
    while read -r c p _; do
        [[ -n "${p:-}" ]] || continue
        base="$(release_base "${p}")"
        at "${base}" "${LAYOUT}" > "${OUT}/layout.base"
        at "${c}" "${LAYOUT}" > "${OUT}/layout.commit"
        base_version="$(at "${base}" VERSION | tr -d '[:space:]')"
        c_version="$(at "${c}" VERSION | tr -d '[:space:]')"
        verdict="$(needs "${OUT}/layout.base" "${base_version:-0.0.0}" "${OUT}/layout.commit" "${c_version}")" \
            || die "commit ${c:0:12} (VERSION ${c_version}) changed ${LAYOUT} against ${base:0:12} (VERSION ${base_version}) without the raised ${verdict%%$'\n'*} it needs: ${verdict#*$'\n'}"
    done < <(git log --format='%H %P' -- "${LAYOUT}")
else
    printf 'check_abi: no full git history here: the version rule is checked where there is one\n'
fi
printf 'check_abi: public ABI matches %s (%s)\n' "${LAYOUT}" "${VERSION_NOW}"
