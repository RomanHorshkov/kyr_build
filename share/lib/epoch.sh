#!/usr/bin/env bash
# shellcheck shell=bash
# epoch.sh — SOURCE_DATE_EPOCH from the build inputs (plan 4.1). The one timestamp a build may embed is the commit time of the
# last commit that touched something a deb is built from; a commit that touches only abi/, tests/, docs/ or a README builds
# byte-identical debs. The default inputs:
#
#   app        sources, public headers, vendored code
#   VERSION    the package version
#   deps.txt   the pins (the toolchain and its flags come from them) and the tier
#   utils      build and packaging scripts, the project file, the linker map, the .pc template in build_deb.sh
#   debian     the copyright file every deb carries
#
# A repository that packages more (a web tree, share/) extends the list in its utils/<name>_project.sh:
#   KYR_BUILD_INPUTS+=(web)
# A SOURCE_DATE_EPOCH the caller exported (a release job, a reproducibility test) always wins; KYR_EPOCH_AUTO=1 marks one
# computed here, which the next entry point recomputes once the project file has extended the inputs.

KYR_BUILD_INPUTS_DEFAULT=(app VERSION deps.txt utils debian)
declare -p KYR_BUILD_INPUTS > /dev/null 2>&1 || KYR_BUILD_INPUTS=("${KYR_BUILD_INPUTS_DEFAULT[@]}")

# kyr_epoch <root> <path ...>: the commit time of the last commit touching any path; HEAD's when none does; 0 outside git.
kyr_epoch() {
    local root="$1" t=""
    shift
    if git -C "${root}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        t="$(git -C "${root}" log -1 --format=%ct -- "$@" 2> /dev/null || true)"
        [[ -n "${t}" ]] || t="$(git -C "${root}" log -1 --format=%ct 2> /dev/null || true)"
    fi
    printf '%s\n' "${t:-0}"
}

# kyr_epoch_init <root>: SOURCE_DATE_EPOCH (exported with TZ=UTC) unless the caller exported one.
kyr_epoch_init() {
    if [[ -z "${SOURCE_DATE_EPOCH:-}" || "${KYR_EPOCH_AUTO:-0}" == 1 ]]; then
        SOURCE_DATE_EPOCH="$(kyr_epoch "$1" "${KYR_BUILD_INPUTS[@]}")"
        KYR_EPOCH_AUTO=1
    fi
    export SOURCE_DATE_EPOCH KYR_EPOCH_AUTO TZ=UTC
}
