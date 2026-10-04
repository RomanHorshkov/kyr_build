#!/usr/bin/env bash
# deps.sh manifest-verify against a stand-in gh: a pin whose hash its release's SHA256SUMS lists passes; a component with no
# release yet is "local, unreleased" (green, red under --strict); a pin the release does not list, a pin without a sha256 and an
# uncached pin each fail.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
mkdir -p "${SCRATCH}/bin" "${SCRATCH}/releases/owner_kyr_alpha_v1.0.0"
# gh: release view/download from ${SCRATCH}/releases/<owner>_<repo>_v<ver>/, "release not found" otherwise
cat > "${SCRATCH}/bin/gh" <<GH
#!/usr/bin/env bash
[[ "\$1" == auth ]] && exit 0
tag="\$3"; repo=""; dir=""
while (( \$# )); do case "\$1" in --repo) repo="\$2"; shift ;; --dir) dir="\$2"; shift ;; esac; shift; done
rel="${SCRATCH}/releases/\${repo//\//_}_\${tag}"
[[ -d "\${rel}" ]] || { echo "release not found" >&2; exit 1; }
[[ -n "\${dir}" ]] && cp "\${rel}/SHA256SUMS" "\${dir}/"
exit 0
GH
chmod +x "${SCRATCH}/bin/gh"
export PATH="${SCRATCH}/bin:${PATH}" GH_TOKEN=stand-in
mkdeb() {  # <pkg>: a tier-4 deb in the test cache, prints its sha256
    local root="${SCRATCH}/pins/$1"; mkdir -p "${root}/DEBIAN"
    printf 'Package: %s\nVersion: 1.0.0\nArchitecture: all\nMaintainer: it\nX-Kyr-Tier: 4 core\nDescription: pin\n' "$1" > "${root}/DEBIAN/control"
    dpkg-deb --build --root-owner-group "${root}" "${KYR_DEPS_CACHE}/debs/$1_1.0.0_all.deb" > /dev/null
    sha256sum "${KYR_DEPS_CACHE}/debs/$1_1.0.0_all.deb" | cut -d' ' -f1
}
a="$(mkdeb libkyr-alpha)"; b="$(mkdeb libkyr-beta)"
printf '%s  libkyr-alpha_1.0.0_all.deb\n' "${a}" > "${SCRATCH}/releases/owner_kyr_alpha_v1.0.0/SHA256SUMS"
read -r kbrepo kb < <(awk '$2=="kyr-build"{print $4, $5}' deps.txt)
mkdir -p "${SCRATCH}/releases/${kbrepo//\//_}_v${VER}"
printf '%s  kyr-build_%s_all.deb\n' "${kb}" "${VER}" > "${SCRATCH}/releases/${kbrepo//\//_}_v${VER}/SHA256SUMS"
printf 'own     libkyr-alpha              1.0.0      owner/kyr_alpha   %s\n' "${a}" >> deps.txt
printf 'own     libkyr-beta               1.0.0      owner/kyr_beta    %s\n' "${b}" >> deps.txt
./utils/deps.sh manifest-verify > "${SCRATCH}/mv.log" 2>&1 || { cat "${SCRATCH}/mv.log"; fail "manifest-verify with one unreleased pin"; }
grep -q 'libkyr-alpha .* ok: cached = pinned = owner/kyr_alpha SHA256SUMS' "${SCRATCH}/mv.log" || fail "released pin"
grep -q 'libkyr-beta .* local, unreleased: cached = pinned; owner/kyr_beta has no release v1.0.0 yet' "${SCRATCH}/mv.log" || fail "unreleased pin"
grep -q "except 1 local, unreleased" "${SCRATCH}/mv.log" || { cat "${SCRATCH}/mv.log"; fail "summary"; }
has 'not released yet' ./utils/deps.sh manifest-verify --strict || fail "--strict"
./utils/deps.sh manifest-verify --strict > /dev/null 2>&1 && fail "--strict passed an unreleased pin"
mkdir -p "${SCRATCH}/releases/owner_kyr_beta_v1.0.0"
printf '%s  libkyr-beta_1.0.0_all.deb\n' "$(printf '0%.0s' {1..64})" > "${SCRATCH}/releases/owner_kyr_beta_v1.0.0/SHA256SUMS"
rm -rf "${KYR_DEPS_CACHE}/sums"
has 'is NOT the hash owner/kyr_beta published' ./utils/deps.sh manifest-verify || fail "a pin its release does not list"
sed -i '$d' deps.txt; printf 'own     libkyr-beta               1.0.0      owner/kyr_beta\n' >> deps.txt
has 'NO sha256 column' ./utils/deps.sh manifest-verify || fail "a pin without sha256"
sed -i '$d' deps.txt; printf 'own     libkyr-gone               1.0.0      owner/kyr_gone    %s\n' "${a}" >> deps.txt
has 'not cached (run: ./utils/deps.sh fetch)' ./utils/deps.sh manifest-verify || fail "an uncached pin"
