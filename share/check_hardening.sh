#!/usr/bin/env bash
# =============================================================================
# check_hardening.sh
#
# author  Roman Horshkov <github.com/RomanHorshkov>
# date    2026
# (c) 2026
# =============================================================================
#
# Assert that built ELF artifacts actually carry the hardening the release
# profile promises. Flags drift silently (stale profile copies, scripts that
# never adopted the catalog, a stray asm object) — this script turns drift
# into a loud red build, same philosophy as the fs_expect permission checks.
#
# Usage:
#   check_hardening.sh <elf> [<elf> ...]
#   check_hardening.sh --ceiling-only <file> [<file> ...]
#                  only the symbol-version ceiling, over every linked ELF among
#                  the files (others are skipped): what the pipeline runs on
#                  every ELF it built, whatever the profile
#
# File kind is auto-detected:
#   shared library : ELF DYN with a DT_SONAME (or no PT_INTERP)
#   executable     : ELF with PT_INTERP (dynamic exe) or DF_1_PIE
#
# HARD checks (any failure => exit 2, fail the build):
#   all   : GNU_STACK segment present and NOT executable
#   all   : GNU_RELRO segment present
#   all   : immediate binding (DT_BIND_NOW / DF_BIND_NOW / DF_1_NOW)
#   all   : no TEXTREL (writable code relocations)
#   all   : no DT_RPATH / DT_RUNPATH — a runpath bakes a build-host path into
#           the shipped bytes and makes the loader search it first; installed
#           libraries resolve through ldconfig, never through the artifact
#   all   : symbol versions within the target: no GLIBC_x.y above
#           KYR_TARGET_GLIBC_MAX (default 2.39, Ubuntu 24.04 noble), no
#           GLIBCXX/CXXABI/GCC above KYR_TARGET_GLIBCXX_MAX (3.4.33),
#           KYR_TARGET_CXXABI_MAX (1.3.15), KYR_TARGET_GCC_MAX (14.0.0), no
#           GLIBC_PRIVATE. Inside the build root the defaults are the root's
#           own libc, libstdc++ and libgcc_s. A box cannot load an ELF that
#           needs a newer version than its libraries define
#   all   : every DT_NEEDED is on the allowlist (libc family, libsodium, liblmdb,
#           zlib, and the platform's own sonames: libkyr_* and the foundation's)
#           — an unexpected dependency is a supply-chain change, not a build
#           detail. Extend per call with
#           CHECK_HARDENING_NEEDED_EXTRA='<ERE over the soname stem>' (e.g.
#           'libcurl|libssl') when a build legitimately adds one
#   exe   : PIE (ELF type DYN + DF_1_PIE)
#   lib   : DT_SONAME present and versioned (lib<x>.so.<N>) — an unversioned
#           soname makes every consumer record an ABI-less dependency
#   ar    : (static archive input) every member is position-independent: no
#           absolute R_X86_64_32/32S relocations, so the archive links into a
#           PIE executable or a shared object on ANY toolchain
#
# SOFT checks (reported as WARN, never fail the build — presence depends on
# code shape, not on build correctness):
#   all   : __stack_chk_fail referenced   (-fstack-protector-strong took effect;
#           a tiny lib with no arrays/address-taken locals legitimately has none)
#   all   : some __*_chk fortified symbol (-D_FORTIFY_SOURCE took effect; absent
#           when every checked call was proven safe at compile time)
#   all   : no "/home/" string anywhere in the file (a build-host path leaked
#           in — debug info, __FILE__, or an embedded path); WARN because
#           debug/native profiles legitimately carry -g comp_dir strings
#   all   : .symtab absent (stripped) — informational: build_libs gates the
#           freshly linked object BEFORE strip, build_deb gates the staged one
#
# Exit codes: 0 all hard checks pass; 2 at least one hard failure; 3 usage.
# =============================================================================
set -euo pipefail

CEILING_ONLY=0
[[ "${1:-}" == --ceiling-only ]] && { CEILING_ONLY=1; shift; }
if (($# < 1)); then
    printf 'usage: %s [--ceiling-only] <elf> [<elf> ...]\n' "$0" >&2
    exit 3
fi

# Symbol-version ceilings: the explicit KYR_TARGET_*_MAX, else the build root's own libraries, else Ubuntu 24.04 noble's.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/root.sh
if [[ -f "${_SCRIPT_DIR}/lib/root.sh" ]]; then source "${_SCRIPT_DIR}/lib/root.sh"; else kyr_root_lib_ceiling() { return 1; }; fi
_ceiling() {  # <prefix> <override> <noble>
    local v="${2}"
    [[ -n "${v}" ]] || v="$(kyr_root_lib_ceiling "$1" 2> /dev/null || true)"
    printf '%s\n' "${v:-$3}"
}
CEIL_GLIBC="$(_ceiling GLIBC "${KYR_TARGET_GLIBC_MAX:-}" 2.39)"
CEIL_GLIBCXX="$(_ceiling GLIBCXX "${KYR_TARGET_GLIBCXX_MAX:-}" 3.4.33)"
CEIL_CXXABI="$(_ceiling CXXABI "${KYR_TARGET_CXXABI_MAX:-}" 1.3.15)"
CEIL_GCC="$(_ceiling GCC "${KYR_TARGET_GCC_MAX:-}" 14.0.0)"

FAILURES=0

_fail() { printf '  \342\234\227 %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
_pass() { printf '  \342\234\223 %s\n' "$1"; }
_warn() { printf '  ! %s (WARN)\n' "$1"; }

# DT_NEEDED allowlist (extended regex over the soname). The platform's own
# libraries, the libc family, and the three system dependencies the release
# stack is allowed to have. Anything else must be added HERE deliberately (or
# passed per call via CHECK_HARDENING_NEEDED_EXTRA) — a NEEDED that nobody
# decided on is exactly the kind of dependency drift this gate exists for.
NEEDED_STEMS='libc|libm|libpthread|libdl|librt|libgcc_s|ld-linux[^ ]*|libsodium|liblmdb|libz|libkyr_[a-z0-9_]+|libemlog|libspscring|libmpscring|libuuid7|libfsutil'
[[ -n "${CHECK_HARDENING_NEEDED_EXTRA:-}" ]] && NEEDED_STEMS+="|${CHECK_HARDENING_NEEDED_EXTRA}"
NEEDED_ALLOW="^(${NEEDED_STEMS})\.so(\.[0-9]+)*$"

# Static archive: every member object must be position-independent. An
# absolute R_X86_64_32 / R_X86_64_32S relocation means the object was compiled
# without -fPIC/-fPIE and cannot go into a PIE executable or a shared object.
check_archive() {
    local a="$1" tmp member rel bad=0 count=0 abs
    printf '%s  [archive]\n' "${a}"
    abs="$(readlink -f "${a}")"
    tmp="$(mktemp -d)"
    if ! (cd "${tmp}" && ar x "${abs}" 2>/dev/null); then
        _fail "cannot extract archive members"
        rm -rf "${tmp}"; return 0
    fi
    for member in "${tmp}"/*.o; do
        [[ -f "${member}" ]] || continue
        count=$((count + 1))
        rel="$(readelf -rW "${member}" 2>/dev/null | awk '$3 ~ /^R_X86_64_32S?$/ {print $3}' | head -1)"
        if [[ -n "${rel}" ]]; then
            _fail "$(basename "${member}"): absolute relocation ${rel} — not position-independent (compile with -fPIC)"
            bad=1
        fi
    done
    rm -rf "${tmp}"
    if (( count == 0 )); then
        _fail "archive has no object members"
    elif (( bad == 0 )); then
        _pass "all ${count} member object(s) position-independent"
    fi
}

_ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }

# ceiling_over <elf>: CEIL_OVER=(every needed symbol version above its ceiling); status 1 when there is one
ceiling_over() {
    local v name ver max
    CEIL_OVER=()
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        if [[ "${v}" == GLIBC_PRIVATE ]]; then CEIL_OVER+=("GLIBC_PRIVATE"); continue; fi
        name="${v%_*}"; ver="${v##*_}"
        case "${name}" in
            GLIBC) max="${CEIL_GLIBC}" ;;
            GLIBCXX) max="${CEIL_GLIBCXX}" ;;
            CXXABI) max="${CEIL_CXXABI}" ;;
            GCC) max="${CEIL_GCC}" ;;
            *) continue ;;
        esac
        _ver_gt "${ver}" "${max}" && CEIL_OVER+=("${v}>${name}_${max}")
    done < <(readelf -VW "$1" 2> /dev/null | awk '/Version needs section/ {n=1; next} /Version (definition|symbols) section/ {n=0} n' |
        grep -oE 'Name: ([A-Za-z_]+_[0-9][0-9.]*|GLIBC_PRIVATE)' | sed 's/^Name: //' | sort -u)
    (( ${#CEIL_OVER[@]} == 0 ))
}
CEIL_MSG="a box with only GLIBC_${CEIL_GLIBC}, GLIBCXX_${CEIL_GLIBCXX}, CXXABI_${CEIL_CXXABI}, GCC_${CEIL_GCC} cannot load it: build inside the build root (build_root.sh enter) or raise KYR_TARGET_*_MAX deliberately"

_linked_elf() {  # <file>: an ELF executable or shared object (not an object file, not an archive)
    [[ "$(head -c 4 "$1" 2> /dev/null | tr -d '\0')" == $'\177ELF' ]] || return 1
    readelf -hW "$1" 2> /dev/null | grep -qE 'Type:[[:space:]]+(EXEC|DYN)'
}

check_file() {
    local f="$1"
    local hdr dyn segs dynsyms kind=lib

    if [[ ! -f "${f}" ]]; then
        printf '%s\n' "${f}"
        _fail "file not found"
        return 0
    fi

    # Static archives get the member-level PIC check and nothing else.
    # (7 bytes: command substitution strips the trailing newline of the 8-byte
    # ar magic; tr drops the NULs an ELF header would otherwise feed bash)
    if [[ "$(head -c 7 "${f}" 2>/dev/null | tr -d '\0')" == '!<arch>' ]]; then
        check_archive "${f}"
        return 0
    fi

    hdr="$(readelf -hW "${f}" 2>/dev/null)" || { printf '%s\n' "${f}"; _fail "not an ELF file"; return 0; }
    dyn="$(readelf -dW "${f}" 2>/dev/null || true)"
    segs="$(readelf -lW "${f}" 2>/dev/null || true)"
    dynsyms="$(readelf -sW "${f}" 2>/dev/null || true)"

    # --- kind detection ------------------------------------------------------
    if grep -q "INTERP" <<< "${segs}" || grep -q "Flags: .*PIE" <<< "${dyn}"; then
        kind=exe
    fi
    printf '%s  [%s]\n' "${f}" "${kind}"

    # --- GNU_STACK: present, not executable ----------------------------------
    local stack_line
    stack_line="$(grep "GNU_STACK" <<< "${segs}" || true)"
    if [[ -z "${stack_line}" ]]; then
        _fail "no GNU_STACK segment (stack executability is unspecified)"
    elif grep -qE "RW?E" <<< "${stack_line}"; then
        _fail "executable stack (GNU_STACK has E) — link with -Wl,-z,noexecstack and find the offending object"
    else
        _pass "non-executable stack"
    fi

    # --- GNU_RELRO ------------------------------------------------------------
    if grep -q "GNU_RELRO" <<< "${segs}"; then
        _pass "GNU_RELRO segment present"
    else
        _fail "no GNU_RELRO segment — link with -Wl,-z,relro"
    fi

    # --- immediate binding (full RELRO) ---------------------------------------
    if grep -qE "BIND_NOW|\(FLAGS_1\).*NOW|\(FLAGS\).*BIND_NOW" <<< "${dyn}"; then
        _pass "immediate binding (full RELRO)"
    else
        _fail "lazy binding — link with -Wl,-z,now (partial RELRO leaves the GOT writable)"
    fi

    # --- TEXTREL ----------------------------------------------------------------
    if grep -qE "TEXTREL" <<< "${dyn}"; then
        _fail "TEXTREL present (writable code relocations) — objects missing -fPIC/-fPIE"
    else
        _pass "no TEXTREL"
    fi

    # --- PIE (executables only) ------------------------------------------------
    if [[ "${kind}" == "exe" ]]; then
        if grep -q "Type:[[:space:]]*DYN" <<< "${hdr}" && grep -qE "\(FLAGS_1\).*PIE" <<< "${dyn}"; then
            _pass "PIE executable (ASLR applies to the image)"
        else
            _fail "not a PIE — compile with -fPIE, link with -pie"
        fi
    fi

    # --- no RPATH / RUNPATH ------------------------------------------------------
    local rp
    rp="$(grep -E "\((RPATH|RUNPATH)\)" <<< "${dyn}" || true)"
    if [[ -n "${rp}" ]]; then
        _fail "$(sed -E 's/.*\((RPATH|RUNPATH)\)[[:space:]]*/\1 /' <<< "${rp}" | head -1) — drop -Wl,-rpath from the link; installed libs resolve via ldconfig"
    else
        _pass "no RPATH/RUNPATH"
    fi

    # --- symbol-version ceiling ---------------------------------------------------
    if ceiling_over "${f}"; then
        _pass "symbol versions within GLIBC_${CEIL_GLIBC} GLIBCXX_${CEIL_GLIBCXX} CXXABI_${CEIL_CXXABI} GCC_${CEIL_GCC}"
    else
        _fail "symbol versions above the target: ${CEIL_OVER[*]} — ${CEIL_MSG}"
    fi

    # --- DT_NEEDED allowlist -----------------------------------------------------
    local needed n unexpected=()
    needed="$(grep -E "\(NEEDED\)" <<< "${dyn}" | sed -E 's/.*\[([^]]+)\].*/\1/' || true)"
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        if ! [[ "${n}" =~ ${NEEDED_ALLOW} ]]; then unexpected+=("${n}"); fi
    done <<< "${needed}"
    if (( ${#unexpected[@]} > 0 )); then
        _fail "unexpected DT_NEEDED: ${unexpected[*]} — not on the allowlist (decide it, then extend NEEDED_ALLOW or CHECK_HARDENING_NEEDED_EXTRA)"
    else
        _pass "every DT_NEEDED on the allowlist"
    fi

    # --- versioned SONAME (shared libraries only) -------------------------------
    if [[ "${kind}" == "lib" ]]; then
        local soname
        soname="$(grep -E "\(SONAME\)" <<< "${dyn}" | sed -E 's/.*\[([^]]+)\].*/\1/' || true)"
        if [[ -z "${soname}" ]]; then
            _fail "no DT_SONAME — link with -Wl,-soname,lib<x>.so.<MAJOR>"
        elif ! [[ "${soname}" =~ \.so\.[0-9]+$ ]]; then
            _fail "unversioned SONAME '${soname}' — consumers would record an ABI-less dependency; use lib<x>.so.<MAJOR>"
        else
            _pass "versioned SONAME ${soname}"
        fi
    fi

    # --- soft: no build-host paths -------------------------------------------------
    if strings -a "${f}" 2>/dev/null | grep -q '/home/'; then
        _warn "'/home/' string present — a build-host path leaked in (debug comp_dir, __FILE__, or an embedded path)"
    else
        _pass "no build-host path strings"
    fi

    # --- soft: stripped ------------------------------------------------------------
    if readelf -SW "${f}" 2>/dev/null | grep -q '\.symtab'; then
        _warn "not stripped (.symtab present) — expected before build_deb's strip, unexpected in a staged deb payload"
    else
        _pass "stripped"
    fi

    # --- soft: stack canaries ---------------------------------------------------
    if grep -q "__stack_chk_fail" <<< "${dynsyms}"; then
        _pass "stack canaries referenced"
    else
        _warn "no __stack_chk_fail reference — no protected frames (fine for tiny libs) or missing -fstack-protector-strong"
    fi

    # --- soft: fortified libc calls ----------------------------------------------
    if grep -qE "__[a-z_]+_chk" <<< "${dynsyms}"; then
        _pass "fortified libc calls present"
    else
        _warn "no __*_chk symbols — all checked calls proven safe, no fortifiable calls, or missing -D_FORTIFY_SOURCE"
    fi
}

if (( CEILING_ONLY )); then
    n=0
    for f in "$@"; do
        _linked_elf "${f}" || continue
        n=$((n + 1))
        ceiling_over "${f}" || { printf '%s\n' "${f}"; _fail "symbol versions above the target: ${CEIL_OVER[*]}"; }
    done
    if ((FAILURES > 0)); then
        printf 'check_hardening: %d ELF(s) above the symbol-version ceiling: %s\n' "${FAILURES}" "${CEIL_MSG}" >&2
        exit 2
    fi
    printf 'check_hardening: %d ELF(s) within GLIBC_%s GLIBCXX_%s CXXABI_%s GCC_%s\n' "${n}" "${CEIL_GLIBC}" "${CEIL_GLIBCXX}" "${CEIL_CXXABI}" "${CEIL_GCC}"
    exit 0
fi

for f in "$@"; do
    check_file "${f}"
    printf '\n'
done

if ((FAILURES > 0)); then
    printf 'check_hardening: %d HARD failure(s)\n' "${FAILURES}" >&2
    exit 2
fi
printf 'check_hardening: all hard checks passed (%d file(s))\n' "$#"
