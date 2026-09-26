#!/usr/bin/env bash
# build_root.sh — the pinned build root (plan 4.1, D27): a root filesystem made with debootstrap from
# snapshot.ubuntu.com at one date, entered with plain chroot/unshare, its hash recorded so CI and the
# workstation prove they built in the same environment.
#
#   build_root.sh create [--dir build/root]      debootstrap the snapshot into the directory (needs root)
#   build_root.sh hash   [--dir build/root]      hash every file (path, mode, content) -> build/root.sha256 (needs root to read all)
#   build_root.sh verify [--dir build/root]      recompute and compare with build/root.sha256
#   build_root.sh enter  [--dir build/root] -- <command ...>
#                                                run the command inside the root with the repository bind-mounted at
#                                                /src; unprivileged through a user namespace when the kernel allows it,
#                                                else print the sudo form of the same command
#   build_root.sh show                           print the pinned suite, snapshot and package set
#
# The pin is data, not a default: change KYR_BUILD_ROOT_SNAPSHOT here, rebuild, record the new hash, and every
# release's buildinfo carries it (Build-Root:). deps.sh sysroot works unchanged inside the root.
set -euo pipefail

KYR_BUILD_ROOT_SUITE="${KYR_BUILD_ROOT_SUITE:-noble}"
KYR_BUILD_ROOT_SNAPSHOT="${KYR_BUILD_ROOT_SNAPSHOT:-20260901T000000Z}"
KYR_BUILD_ROOT_MIRROR="https://snapshot.ubuntu.com/ubuntu/${KYR_BUILD_ROOT_SNAPSHOT}"
KYR_BUILD_ROOT_PACKAGES="${KYR_BUILD_ROOT_PACKAGES:-build-essential,dpkg-dev,fakeroot,pkg-config,git,ca-certificates,curl,python3,libcmocka-dev,gcovr,clang,clang-format-18,libsodium-dev,liblmdb-dev,zlib1g-dev,binutils}"

ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"
DIR="${ROOT_DIR}/build/root"
HASH_FILE="${ROOT_DIR}/build/root.sha256"

die() { printf 'build_root.sh: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 3; }

CMD="${1:-}"; shift || true
while (( $# )); do
    case "$1" in
        --dir) DIR="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")" || DIR="$2"; HASH_FILE="${DIR}.sha256"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

need_root() { (( EUID == 0 )) || die "$1 needs root: sudo ${BASH_SOURCE[0]} $1 --dir ${DIR}"; }

cmd_show() {
    printf 'suite:    %s\nsnapshot: %s\nmirror:   %s\npackages: %s\nroot:     %s\nhash:     %s\n' \
        "${KYR_BUILD_ROOT_SUITE}" "${KYR_BUILD_ROOT_SNAPSHOT}" "${KYR_BUILD_ROOT_MIRROR}" "${KYR_BUILD_ROOT_PACKAGES}" "${DIR}" \
        "$( [[ -f "${HASH_FILE}" ]] && awk '{print $1}' "${HASH_FILE}" || printf 'not recorded')"
}

cmd_create() {
    need_root create
    command -v debootstrap >/dev/null 2>&1 || die "debootstrap not found (apt install debootstrap)"
    [[ -e "${DIR}" ]] && die "${DIR} exists; remove it first"
    mkdir -p "$(dirname "${DIR}")"
    debootstrap --variant=minbase --include="${KYR_BUILD_ROOT_PACKAGES}" "${KYR_BUILD_ROOT_SUITE}" "${DIR}" "${KYR_BUILD_ROOT_MIRROR}"
    # apt inside the root stays on the snapshot: nothing floats after creation either.
    cat > "${DIR}/etc/apt/sources.list" <<EOF
deb ${KYR_BUILD_ROOT_MIRROR} ${KYR_BUILD_ROOT_SUITE} main universe
deb ${KYR_BUILD_ROOT_MIRROR} ${KYR_BUILD_ROOT_SUITE}-updates main universe
deb ${KYR_BUILD_ROOT_MIRROR} ${KYR_BUILD_ROOT_SUITE}-security main universe
EOF
    printf 'Acquire::Check-Valid-Until "false";\n' > "${DIR}/etc/apt/apt.conf.d/99snapshot"
    printf '%s\n' "${KYR_BUILD_ROOT_SNAPSHOT}" > "${DIR}/etc/kyr-build-root-snapshot"
    mkdir -p "${DIR}/src"
    # The root's own logs, caches and machine identity are not part of the environment.
    rm -rf "${DIR}/var/cache/apt/"*.bin "${DIR}/var/lib/apt/lists/"* "${DIR}/var/log/"* "${DIR}/etc/machine-id" "${DIR}/var/lib/dbus/machine-id"
    cmd_hash
}

# One line per file: path, mode, sha256 of the content (symlinks: their target). Sorted, so the digest of the
# listing is the root's hash. /src, /proc, /sys, /dev, /tmp and /run are the machine's, never the root's.
hash_listing() {
    ( cd "${DIR}" && find . -mindepth 1 \( -path ./src -o -path ./proc -o -path ./sys -o -path ./dev -o -path ./tmp -o -path ./run -o -path ./var/tmp \) -prune -o \( -type f -o -type l \) -print0 |
        LC_ALL=C sort -z | while IFS= read -r -d '' f; do
            if [[ -L "${f}" ]]; then printf '%s l %s\n' "${f#./}" "$(readlink "${f}")"
            else printf '%s %s %s\n' "${f#./}" "$(stat -c %a "${f}")" "$(sha256sum "${f}" | awk '{print $1}')"; fi
        done )
}

cmd_hash() {
    [[ -d "${DIR}" ]] || die "no build root at ${DIR}"
    local sum
    sum="$(hash_listing | sha256sum | awk '{print $1}')"
    printf '%s  %s %s\n' "${sum}" "${KYR_BUILD_ROOT_SUITE}" "${KYR_BUILD_ROOT_SNAPSHOT}" > "${HASH_FILE}"
    printf 'build root hash: %s (recorded in %s)\n' "${sum}" "${HASH_FILE}"
}

cmd_verify() {
    [[ -f "${HASH_FILE}" ]] || die "no recorded hash at ${HASH_FILE} (run: build_root.sh hash)"
    local want have
    want="$(awk '{print $1}' "${HASH_FILE}")"
    have="$(hash_listing | sha256sum | awk '{print $1}')"
    [[ "${want}" == "${have}" ]] || die "build root drifted: recorded ${want}, now ${have}"
    printf 'build root matches %s\n' "${want}"
}

cmd_enter() {
    [[ -d "${DIR}" ]] || die "no build root at ${DIR} (run: sudo build_root.sh create)"
    (( $# )) || die "enter needs a command after --"
    local -a inner=(sh -c 'mount --bind "$1" /src && mount -t proc proc /proc && cd /src && shift && exec "$@"' enter)
    export KYR_BUILD_ROOT_HASH
    KYR_BUILD_ROOT_HASH="$( [[ -f "${HASH_FILE}" ]] && awk '{print $1}' "${HASH_FILE}" || printf 'unrecorded')"
    if (( EUID == 0 )); then
        exec unshare --mount --pid --fork --propagation private chroot "${DIR}" "${inner[@]}" "${ROOT_DIR}" "$@"
    fi
    if unshare --user --map-root-user --mount --pid --fork --propagation private true 2>/dev/null; then
        # The repository is bind-mounted before chroot so the path exists inside the root; unprivileged user
        # namespaces need the root tree world-readable, which debootstrap output is.
        exec unshare --user --map-root-user --mount --pid --fork --propagation private \
            sh -c 'mount --bind "$1" "$2/src" && exec chroot "$2" sh -c "mount -t proc proc /proc; cd /src && exec \"\$@\"" enter "${@:3}"' enter "${ROOT_DIR}" "${DIR}" "$@"
    fi
    die "unprivileged user namespaces are disabled here; run: sudo KYR_BUILD_ROOT_HASH=${KYR_BUILD_ROOT_HASH} ${BASH_SOURCE[0]} enter --dir ${DIR} -- $*"
}

case "${CMD}" in
    show) cmd_show ;;
    create) cmd_create ;;
    hash) cmd_hash ;;
    verify) cmd_verify ;;
    enter) cmd_enter "$@" ;;
    *) usage ;;
esac
