#!/usr/bin/env bash
# shellcheck shell=bash
# tier.sh — the tier declaration (plan 2.1). A repository states its own tier in deps.txt with one header line:
#
#   # tier: <n> <kind>        build 0, foundation 1, platform 2, host 3, core 4, product 5, composition 6,
#                             platform-definition 7, fleet 8 (the number is the kind's; both are written)
#
# lib/deb.sh copies it into every deb it builds as `X-Kyr-Tier: <n> <kind>`, so a consumer reads the tier of what it pins
# from the pinned deb itself, and deps.sh check --tiers compares. tiers.txt lists only the platform's fixed repositories, as
# a cross-check; a repository it does not list is a product, and adding a product changes nothing here.

declare -gA KYR_TIER_KINDS=(
    [build]=0 [foundation]=1 [platform]=2 [host]=3 [core]=4 [product]=5 [composition]=6 [platform-definition]=7 [fleet]=8
)

# kyr_tier_valid "<n> <kind>": a known kind with its own number, nothing else on the line.
kyr_tier_valid() {
    local n kind extra
    read -r n kind extra <<< "$1"
    [[ -z "${extra}" && -n "${kind}" && -n "${KYR_TIER_KINDS[${kind}]+x}" && "${n}" == "${KYR_TIER_KINDS[${kind}]}" ]]
}

# kyr_tier_declared <deps.txt>: prints "<n> <kind>"; fails with the reason on stderr unless the file carries exactly one
# well-formed header line.
kyr_tier_declared() {
    local file="$1" lines count decl
    [[ -f "${file}" ]] || { printf 'tier: no %s\n' "${file}" >&2; return 1; }
    lines="$(grep -E '^#[[:space:]]*tier:' "${file}" || true)"
    count="$(grep -c . <<< "${lines}" || true)"
    if (( count != 1 )); then
        printf 'tier: %s must declare its tier once, as "# tier: <n> <kind>" (found %s)\n' "${file}" "${count}" >&2
        return 1
    fi
    decl=""
    [[ "${lines}" =~ ^\#\ tier:\ ([0-9]+\ [a-z-]+)[[:space:]]*$ ]] && decl="${BASH_REMATCH[1]}"
    if [[ -z "${decl}" ]] || ! kyr_tier_valid "${decl}"; then
        printf 'tier: %s: "%s" is not "# tier: <n> <kind>" with n the kind'"'"'s tier (build 0, foundation 1, platform 2, host 3, core 4, product 5, composition 6, platform-definition 7, fleet 8)\n' "${file}" "${lines}" >&2
        return 1
    fi
    printf '%s\n' "${decl}"
}
