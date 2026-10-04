#!/usr/bin/env bash
# shellcheck shell=bash
# kyr.sh — what every utils/ wrapper sources after the profile catalog: the project file (utils/<name>_project.sh, declarations
# only), then the build, test and packaging steps, so that a wrapper is one call.
_kyr_projects=("${ROOT_DIR}"/utils/*_project.sh)
# shellcheck source=/dev/null
[[ -f "${_kyr_projects[0]}" ]] && source "${_kyr_projects[0]}"
# shellcheck source=build.sh
source "${KYR_BUILD_DIR}/lib/build.sh"
# shellcheck source=deb.sh
source "${KYR_BUILD_DIR}/lib/deb.sh"

# kyr_each_profile <function> <default profile> [--profile] [profile ...]: the function once per profile; CI's --profile flag
# is accepted and dropped
kyr_each_profile() {
    local fn="$1" def="$2" p profiles=()
    shift 2
    for p in "$@"; do [[ "${p}" == --profile ]] || profiles+=("${p}"); done
    (( ${#profiles[@]} )) || profiles=("${def}")
    for p in "${profiles[@]}"; do "${fn}" "${p}"; done
}
