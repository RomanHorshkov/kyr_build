#!/usr/bin/env bash
# build_root.sh — the pinned build root (D27, D48): Ubuntu Base 24.04 (one point-release tarball, its sha256 pinned) with apt on
# snapshot.ubuntu.com at one date, made and entered without root through bwrap. Every release is built inside it; the host's
# own toolchain is for development only.
#
#   build_root.sh create [--dir D] [--rootless | --debootstrap]
#                                make the root: --rootless (the default) extracts the tarball as the user and runs apt inside
#                                bwrap --unshare-user --uid 0; --debootstrap (needs root) is the older recipe
#   build_root.sh hash   [--dir D]  record D.id: suite, snapshot, tarball sha256, identity, files hash
#   build_root.sh verify [--dir D]  recompute the identity (dpkg-query inside the root) and the files hash, compare with D.id
#   build_root.sh enter  [--dir D] [--src S] [--offline] -- <command ...>
#                                run the command inside the root (read-only) with S (default: the current directory) at /src
#                                as the working directory, the deb cache read-write at the path the tools use, a throwaway
#                                HOME, the host's network unless --offline
#   build_root.sh show   [--dir D]  suite, snapshot, tarball, package set, identity, files hash, toolchain versions
#   build_root.sh destroy [--dir D] remove the root and its record
#
# D defaults to ${XDG_CACHE_HOME:-~/.cache}/kyr-build-root/<suite>-<snapshot> (KYR_BUILD_ROOT_HOME moves the parent).
# Identity: sha256 of the suite, the snapshot, the tarball sha256 and the installed package list (dpkg-query inside the root),
# so two machines that made the root from the same pins share it. It is written into the root as /etc/kyr-build-root:
# buildinfo.sh records it as Build-Root, lib/deb.sh refuses a release without it, check_hardening.sh takes its symbol-version
# ceilings from the root's libraries. The files hash (path, mode, content of every file) proves this copy unchanged.
# enter checks the identity and passes only KYR_BUILD_ROOT_ENV names (plus a short fixed list) into the root.
set -euo pipefail

KYR_BUILD_ROOT_SUITE="${KYR_BUILD_ROOT_SUITE:-noble}"
KYR_BUILD_ROOT_SNAPSHOT="${KYR_BUILD_ROOT_SNAPSHOT:-20260901T000000Z}"
KYR_BUILD_ROOT_TARBALL="${KYR_BUILD_ROOT_TARBALL:-ubuntu-base-24.04.5-base-amd64.tar.gz}"
KYR_BUILD_ROOT_TARBALL_SHA256="${KYR_BUILD_ROOT_TARBALL_SHA256:-e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86}"
KYR_BUILD_ROOT_TARBALL_URL="${KYR_BUILD_ROOT_TARBALL_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/${KYR_BUILD_ROOT_TARBALL}}"
KYR_BUILD_ROOT_MIRROR="https://snapshot.ubuntu.com/ubuntu/${KYR_BUILD_ROOT_SNAPSHOT}"
KYR_BUILD_ROOT_PACKAGES="${KYR_BUILD_ROOT_PACKAGES:-build-essential,dpkg-dev,fakeroot,pkg-config,git,ca-certificates,curl,python3,libcmocka-dev,gcovr,clang,libclang-rt-18-dev,clang-format-18,nodejs,jq,xxd,libsodium-dev,liblmdb-dev,zlib1g-dev,binutils}"
KYR_BUILD_ROOT_HOME="${KYR_BUILD_ROOT_HOME:-${XDG_CACHE_HOME:-${HOME}/.cache}/kyr-build-root}"
ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MARKER=etc/kyr-build-root
FORMAT=kyr-build-root/1

DIR="${KYR_BUILD_ROOT_HOME}/${KYR_BUILD_ROOT_SUITE}-${KYR_BUILD_ROOT_SNAPSHOT}"
SRC=""; OFFLINE=0; METHOD=rootless

die() { printf 'build_root.sh: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_root.sh: %s\n' "$*" >&2; }
usage() { sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 3; }
abspath() { local d; d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || die "no directory for $1"; printf '%s/%s\n' "${d}" "$(basename "$1")"; }

CMD="${1:-}"; shift || true
while (( $# )); do
    case "$1" in
        --dir) [[ -n "${2:-}" ]] || die "--dir needs a path"; DIR="$(abspath "$2")"; shift 2 ;;
        --src) [[ -d "${2:-}" ]] || die "--src needs a directory"; SRC="$(cd "$2" && pwd -P)"; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        --rootless) METHOD=rootless; shift ;;
        --debootstrap) METHOD=debootstrap; shift ;;
        --) shift; break ;;
        *) die "unknown option $1" ;;
    esac
done
ID_FILE="${DIR}.id"

need_bwrap() { command -v bwrap > /dev/null 2>&1 || die "bwrap not found (apt install bubblewrap)"; }
host_resolv() { readlink -f /etc/resolv.conf; }

# marker_field <root> <field>: one field of the root's /etc/kyr-build-root
marker_field() { [[ -f "$1/${MARKER}" ]] && awk -F': ' -v k="$2" '$1==k {print $2; f=1} END {exit !f}' "$1/${MARKER}"; }
# id_field <field>: one field of D.id
id_field() { [[ -f "${ID_FILE}" ]] && awk -F': ' -v k="$1" '$1==k {print $2; f=1} END {exit !f}' "${ID_FILE}"; }

# root_packages <root>: "<package>:<arch> <version>" for every installed package, C-sorted (dpkg-query inside the root;
# the host's dpkg-query on the root's database when bwrap is missing)
root_packages() {
    local fmt='${db:Status-Status} ${Package}:${Architecture} ${Version}\n'
    if command -v bwrap > /dev/null 2>&1; then
        bwrap --ro-bind "$1" / --proc /proc --dev /dev --unshare-all --die-with-parent --clearenv --setenv PATH "${ROOT_PATH}" \
            dpkg-query -W -f "${fmt}"
    else
        dpkg-query --admindir="$1/var/lib/dpkg" -W -f "${fmt}"
    fi | awk '$1=="installed" {print $2, $3}' | LC_ALL=C sort
}

# identity_of <root> <suite> <snapshot> <tarball sha256>
identity_of() {
    { printf '%s\nsuite %s\nsnapshot %s\ntarball %s\n' "${FORMAT}" "$2" "$3" "$4"; root_packages "$1"; } | sha256sum | awk '{print $1}'
}

# hash_listing <root>: "<path>\t<mode>\t<sha256>" per file ("unreadable" when the user cannot read it), "<path>\tl\t<target>" per
# symlink, C-sorted. /src, /proc, /sys, /dev, /tmp, /run and /var/tmp belong to the machine, never to the root.
hash_listing() {
    ( cd "$1" || exit 1
      local prune=( \( -path ./src -o -path ./proc -o -path ./sys -o -path ./dev -o -path ./tmp -o -path ./run -o -path ./var/tmp \) -prune -o )
      {
          find . -mindepth 1 "${prune[@]}" -type l -printf '%P\tl\t%l\n'
          find . -mindepth 1 "${prune[@]}" -type f ! -readable -printf '%P\t%m\tunreadable\n'
          awk -F'\t' 'NR==FNR {mode[$1]=$2; next} {p=substr($0, 67); printf "%s\t%s\t%s\n", p, mode[p], substr($0, 1, 64)}' \
              <(find . -mindepth 1 "${prune[@]}" -type f -readable -printf '%P\t%m\n') \
              <(find . -mindepth 1 "${prune[@]}" -type f -readable -printf '%P\0' | xargs -0 -r sha256sum -z -- | tr '\0' '\n')
      } | LC_ALL=C sort )
}
files_hash() { hash_listing "$1" | sha256sum | awk '{print $1}'; }

fetch_tarball() {  # <path>: the pinned tarball, downloaded once, refused unless its sha256 is the pinned one
    local t="$1" have
    if [[ ! -f "${t}" ]]; then
        command -v curl > /dev/null 2>&1 || die "curl not found"
        mkdir -p "$(dirname "${t}")"
        say "fetching ${KYR_BUILD_ROOT_TARBALL_URL}"
        curl -fsSL --retry 3 -o "${t}.part" "${KYR_BUILD_ROOT_TARBALL_URL}" || die "download failed: ${KYR_BUILD_ROOT_TARBALL_URL}"
        mv "${t}.part" "${t}"
    fi
    have="$(sha256sum "${t}" | awk '{print $1}')"
    [[ "${have}" == "${KYR_BUILD_ROOT_TARBALL_SHA256}" ]] || { rm -f "${t}"; die "${t}: sha256 ${have}, pinned ${KYR_BUILD_ROOT_TARBALL_SHA256} (removed)"; }
}

remove_tree() { [[ -e "$1" ]] || return 0; chmod -R u+w "$1" 2> /dev/null || true; rm -rf "$1"; }

prepare_apt() {  # <root>: apt on the snapshot, no services, a resolver bind target, /src
    local r="$1"
    rm -f "${r}/etc/apt/sources.list.d/"*
    cat > "${r}/etc/apt/sources.list" <<EOF
deb ${KYR_BUILD_ROOT_MIRROR} ${KYR_BUILD_ROOT_SUITE} main universe
deb ${KYR_BUILD_ROOT_MIRROR} ${KYR_BUILD_ROOT_SUITE}-updates main universe
deb ${KYR_BUILD_ROOT_MIRROR} ${KYR_BUILD_ROOT_SUITE}-security main universe
EOF
    # The snapshot never expires; apt runs as uid 0 of a user namespace, which has no _apt user to drop to.
    cat > "${r}/etc/apt/apt.conf.d/99kyr-build-root" <<'EOF'
Acquire::Check-Valid-Until "false";
APT::Sandbox::User "root";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
Dpkg::Use-Pty "false";
EOF
    printf '#!/bin/sh\nexit 101\n' > "${r}/usr/sbin/policy-rc.d"
    chmod 0755 "${r}/usr/sbin/policy-rc.d"
    rm -f "${r}/etc/resolv.conf"; : > "${r}/etc/resolv.conf"
    # fontconfig-config's postinst gives a /usr/local/share/fonts it creates to root:staff, a group the user namespace does not map,
    # and the install fails; made here, the postinst leaves it as it is
    mkdir -p "${r}/src" "${r}/usr/local/share/fonts"
}

apt_install() {  # <root>: apt-get update and install of the package set, as uid 0 of a user namespace
    local r="$1" ca=/etc/ssl/certs/ca-certificates.crt
    [[ -f "${ca}" ]] || die "no host CA bundle at ${ca} (apt reaches the snapshot over https)"
    bwrap --bind "${r}" / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /run \
        --ro-bind "$(host_resolv)" /etc/resolv.conf --ro-bind "${ca}" /run/kyr-ca.crt \
        --unshare-user --uid 0 --gid 0 --unshare-pid --unshare-ipc --unshare-uts --hostname kyr-build-root --die-with-parent \
        --clearenv --setenv PATH "${ROOT_PATH}" --setenv HOME /root --setenv LANG C.UTF-8 --setenv DEBIAN_FRONTEND noninteractive \
        /bin/sh -euc 'o="-o Acquire::https::CAInfo=/run/kyr-ca.crt"; apt-get $o update; apt-get $o -y install $1; apt-get clean' \
        apt "${KYR_BUILD_ROOT_PACKAGES//,/ }"
}

finish_root() {  # <root> <tarball> <tarball sha256>: drop what is not environment, write the marker
    local r="$1" id
    rm -rf "${r}/var/lib/apt/lists/"* "${r}/var/cache/apt/"*.bin "${r}/var/cache/apt/archives/"*.deb "${r}/var/log/"* \
        "${r}/var/cache/ldconfig/aux-cache" "${r}/var/lib/dpkg/"*-old "${r}/var/cache/debconf/"*-old \
        "${r}/etc/machine-id" "${r}/var/lib/dbus/machine-id" "${r}/root/.cache"
    mkdir -p "${r}/var/lib/apt/lists/partial"
    id="$(identity_of "${r}" "${KYR_BUILD_ROOT_SUITE}" "${KYR_BUILD_ROOT_SNAPSHOT}" "$3")"
    printf 'Format: %s\nSuite: %s\nSnapshot: %s\nTarball: %s\nTarball-Sha256: %s\nPackages: %s\nIdentity: %s\n' \
        "${FORMAT}" "${KYR_BUILD_ROOT_SUITE}" "${KYR_BUILD_ROOT_SNAPSHOT}" "$2" "$3" "${KYR_BUILD_ROOT_PACKAGES}" "${id}" > "${r}/${MARKER}"
    chmod 0644 "${r}/${MARKER}"
}

cmd_create() {
    [[ -e "${DIR}" ]] && die "${DIR} exists (build_root.sh destroy --dir ${DIR})"
    local part="${DIR}.partial"
    remove_tree "${part}"
    mkdir -p "${part}"
    if [[ "${METHOD}" == debootstrap ]]; then
        (( EUID == 0 )) || die "--debootstrap needs root (the default, --rootless, does not)"
        command -v debootstrap > /dev/null 2>&1 || die "debootstrap not found"
        debootstrap --variant=minbase --include="${KYR_BUILD_ROOT_PACKAGES}" "${KYR_BUILD_ROOT_SUITE}" "${part}" "${KYR_BUILD_ROOT_MIRROR}"
        prepare_apt "${part}"
        finish_root "${part}" debootstrap none
    else
        need_bwrap
        local tarball="${KYR_BUILD_ROOT_HOME}/${KYR_BUILD_ROOT_TARBALL}"
        fetch_tarball "${tarball}"
        # As the user: every file becomes the user's (uid 0 inside the namespace); device nodes are skipped, bwrap gives /dev.
        tar -xpzf "${tarball}" -C "${part}" --no-same-owner --exclude='dev/*' --exclude='./dev/*'
        prepare_apt "${part}"
        apt_install "${part}"
        finish_root "${part}" "${KYR_BUILD_ROOT_TARBALL}" "${KYR_BUILD_ROOT_TARBALL_SHA256}"
    fi
    mv "${part}" "${DIR}"
    cmd_hash
}

need_dir() { [[ -f "${DIR}/${MARKER}" ]] || die "no build root at ${DIR} (build_root.sh create)"; }

cmd_hash() {
    need_dir
    local suite snap tsha id have files
    suite="$(marker_field "${DIR}" Suite)"; snap="$(marker_field "${DIR}" Snapshot)"; tsha="$(marker_field "${DIR}" Tarball-Sha256)"
    id="$(marker_field "${DIR}" Identity)"
    have="$(identity_of "${DIR}" "${suite}" "${snap}" "${tsha}")"
    [[ "${have}" == "${id}" ]] || die "the package set changed since create: identity ${have}, marker ${id}"
    files="$(files_hash "${DIR}")"
    printf 'Format: %s\nSuite: %s\nSnapshot: %s\nTarball: %s\nTarball-Sha256: %s\nIdentity: %s\nFiles-Sha256: %s\n' \
        "${FORMAT}" "${suite}" "${snap}" "$(marker_field "${DIR}" Tarball)" "${tsha}" "${id}" "${files}" > "${ID_FILE}"
    printf 'build root %s\n  identity %s\n  files    %s\n  recorded in %s\n' "${DIR}" "${id}" "${files}" "${ID_FILE}"
}

cmd_verify() {
    need_dir
    [[ -f "${ID_FILE}" ]] || die "no record at ${ID_FILE} (build_root.sh hash)"
    local want_id want_files id files
    want_id="$(id_field Identity)"; want_files="$(id_field Files-Sha256)"
    id="$(identity_of "${DIR}" "$(marker_field "${DIR}" Suite)" "$(marker_field "${DIR}" Snapshot)" "$(marker_field "${DIR}" Tarball-Sha256)")"
    [[ "${id}" == "${want_id}" && "$(marker_field "${DIR}" Identity)" == "${want_id}" ]] || die "identity drifted: recorded ${want_id}, now ${id}"
    files="$(files_hash "${DIR}")"
    [[ "${files}" == "${want_files}" ]] || die "files drifted: recorded ${want_files}, now ${files}"
    printf 'build root matches: identity %s, files %s\n' "${id}" "${files}"
}

cmd_show() {
    printf 'suite:     %s\nsnapshot:  %s (%s)\ntarball:   %s %s\nrequested: %s\nroot:      %s\n' \
        "${KYR_BUILD_ROOT_SUITE}" "${KYR_BUILD_ROOT_SNAPSHOT}" "${KYR_BUILD_ROOT_MIRROR}" "${KYR_BUILD_ROOT_TARBALL}" \
        "${KYR_BUILD_ROOT_TARBALL_SHA256}" "${KYR_BUILD_ROOT_PACKAGES}" "${DIR}"
    if [[ ! -f "${DIR}/${MARKER}" ]]; then printf 'state:     not created (build_root.sh create)\n'; return 0; fi
    local pkgs
    pkgs="$(root_packages "${DIR}")"
    printf 'identity:  %s\nfiles:     %s\npackages:  %s installed\n' "$(marker_field "${DIR}" Identity)" \
        "$(id_field Files-Sha256 || printf 'not recorded (build_root.sh hash)')" "$(wc -l <<< "${pkgs}")"
    awk '{split($1, a, ":"); if (a[1] ~ /^(gcc-[0-9]+|libc6|binutils|dpkg|clang-[0-9]+|libstdc\+\+6|python3\.[0-9]+|git)$/) printf "  %-14s %s\n", a[1], $2}' <<< "${pkgs}"
    [[ "$(marker_field "${DIR}" Snapshot)" == "${KYR_BUILD_ROOT_SNAPSHOT}" && "$(marker_field "${DIR}" Tarball-Sha256)" =~ ^(${KYR_BUILD_ROOT_TARBALL_SHA256}|none)$ ]] ||
        printf 'note:      this root was made from other pins (%s, %s): recreate it\n' "$(marker_field "${DIR}" Snapshot)" "$(marker_field "${DIR}" Tarball)"
}

cmd_enter() {
    need_dir; need_bwrap
    (( $# )) || die "enter needs a command after --"
    local id have src user uid gid home_in cache cache_in name
    id="$(marker_field "${DIR}" Identity)"
    have="$(identity_of "${DIR}" "$(marker_field "${DIR}" Suite)" "$(marker_field "${DIR}" Snapshot)" "$(marker_field "${DIR}" Tarball-Sha256)")"
    [[ "${have}" == "${id}" ]] || die "the root's package set drifted (identity ${have}, marker ${id}): recreate it"
    src="${SRC:-$(pwd -P)}"
    user="$(id -un)"; uid="$(id -u)"; gid="$(id -g)"
    if (( uid == 0 )); then home_in=/root; else home_in="/home/${user}"; fi
    cache="${KYR_DEPS_CACHE:-${RH_DEPS_CACHE:-${HOME}/.cache/rh-deps}}"
    mkdir -p "${cache}/debs"; cache="$(cd "${cache}" && pwd -P)"
    case "${cache}" in /home/*|/root/*|/tmp/*) cache_in="${cache}" ;; *) cache_in="${home_in}/.cache/rh-deps" ;; esac
    # What crosses into the root: the identity, the cache, and only these names from the caller's environment.
    local -a env_args=()
    for name in TERM NO_COLOR CI GCC_BUILD_ENABLE_TSAN KYR_PIPELINE_FAIL_FAST KYR_FUZZ_SECONDS KYR_CLANG_FORMAT_MAJOR \
        KYR_TARGET_GLIBC_MAX KYR_TARGET_GLIBCXX_MAX KYR_TARGET_CXXABI_MAX KYR_TARGET_GCC_MAX CHECK_HARDENING_NEEDED_EXTRA ${KYR_BUILD_ROOT_ENV:-}; do
        [[ -n "${!name+x}" ]] && env_args+=(--setenv "${name}" "${!name}")
    done
    [[ -n "${SOURCE_DATE_EPOCH:-}" && "${KYR_EPOCH_AUTO:-0}" != 1 ]] && env_args+=(--setenv SOURCE_DATE_EPOCH "${SOURCE_DATE_EPOCH}")
    local -a net=(--ro-bind "$(host_resolv)" /etc/resolv.conf)
    (( OFFLINE )) && net=(--unshare-net)
    exec 3< <(awk -F: -v u="${user}" -v i="${uid}" '$1!=u && $3!=i' "${DIR}/etc/passwd"; (( uid == 0 )) || printf '%s:x:%s:%s::%s:/bin/bash\n' "${user}" "${uid}" "${gid}" "${home_in}")
    exec 4< <(awk -F: -v g="${gid}" '$3!=g' "${DIR}/etc/group"; (( gid == 0 )) || printf '%s:x:%s:\n' "${user}" "${gid}")
    exec bwrap --ro-bind "${DIR}" / --dev /dev --proc /proc --ro-bind /sys /sys \
        --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run --tmpfs /home --tmpfs /root "${net[@]}" \
        --ro-bind-data 3 /etc/passwd --ro-bind-data 4 /etc/group \
        --dir "${home_in}" --bind "${src}" /src --bind "${cache}" "${cache_in}" \
        --unshare-user --unshare-pid --unshare-ipc --unshare-uts --hostname kyr-build-root --die-with-parent \
        --clearenv --setenv PATH "${ROOT_PATH}" --setenv HOME "${home_in}" --setenv USER "${user}" --setenv LOGNAME "${user}" \
        --setenv LANG C.UTF-8 --setenv KYR_BUILD_ROOT_ID "${id}" --setenv KYR_BUILD_ROOT_HASH "${id}" \
        --setenv KYR_DEPS_CACHE "${cache_in}" --setenv RH_DEPS_CACHE "${cache_in}" "${env_args[@]}" \
        --chdir /src -- "$@"
}

cmd_destroy() {
    [[ -e "${DIR}" || -e "${ID_FILE}" ]] || die "no build root at ${DIR}"
    remove_tree "${DIR}"; rm -f "${ID_FILE}"
    printf 'removed %s\n' "${DIR}"
}

case "${CMD}" in
    create) cmd_create ;;
    hash) cmd_hash ;;
    verify) cmd_verify ;;
    enter) cmd_enter "$@" ;;
    show) cmd_show ;;
    destroy) cmd_destroy ;;
    *) usage ;;
esac
