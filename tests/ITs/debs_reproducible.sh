#!/usr/bin/env bash
# Gate 1.4 for the tooling itself: building the debs a second time gives byte-identical files.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT_DIR="${SCRATCH}/debs2" "${ROOT_DIR}/utils/build_deb.sh" > /dev/null
diff <(sed 's| .*/| |' "${DEBS}/SHA256SUMS") <(sed 's| .*/| |' "${SCRATCH}/debs2/SHA256SUMS") || fail "a second build of the debs differs"
for f in "${DEBS}"/*.deb; do
    [[ -f "${f}.buildinfo" ]] || fail "no buildinfo next to $(basename "${f}")"
    grep -q "^Deb-Sha256: $(sha256sum "${f}" | awk '{print $1}')$" "${f}.buildinfo" || fail "buildinfo hash mismatch for $(basename "${f}")"
    grep -q '^Source-Date-Epoch: [0-9]' "${f}.buildinfo" || fail "buildinfo without SOURCE_DATE_EPOCH"
done
