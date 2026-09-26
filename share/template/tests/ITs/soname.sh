#!/usr/bin/env bash
# The release shared object carries a versioned soname equal to the major of VERSION.
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ver="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
so="$(ls "${ROOT_DIR}"/build/release/lib*.so."${ver}")"
readelf -d "${so}" | grep -q "SONAME.*\.so\.${ver%%.*}\]"
