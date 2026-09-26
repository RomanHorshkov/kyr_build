#!/usr/bin/env bash
# run_ITs.sh — every tests/ITs/*.sh against build/debs; exit 1 on any failure.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
for t in "${ROOT_DIR}"/tests/ITs/*.sh; do
    [[ "$(basename "${t}")" == lib.sh ]] && continue
    printf '== %s\n' "$(basename "${t}")"
    if bash "${t}"; then printf '   ok\n'; else printf '   FAIL\n'; rc=1; fi
done
exit "${rc}"
