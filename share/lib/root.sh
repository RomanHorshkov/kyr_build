#!/usr/bin/env bash
# shellcheck shell=bash
# root.sh — where a build runs: inside the pinned build root (build_root.sh enter, which carries /etc/kyr-build-root) or on the
# host. Sourced by buildinfo.sh, lib/deb.sh, pipeline.sh and check_hardening.sh.
#
#   kyr_root_identity            the identity of the build root this process runs in; status 1 on the host
#   kyr_root_release_check       status 0 inside the root, or on the host with KYR_ALLOW_HOST_BUILD=1 (a development deb)
#   kyr_root_lib_ceiling <prefix> the highest <prefix>_x.y version the root's libc, libstdc++ or libgcc_s defines (GLIBC,
#                                GLIBCXX, CXXABI, GCC); status 1 on the host

KYR_BUILD_ROOT_MARKER="${KYR_BUILD_ROOT_MARKER:-/etc/kyr-build-root}"

kyr_root_identity() {
    [[ -r "${KYR_BUILD_ROOT_MARKER}" ]] || return 1
    awk -F': ' '$1=="Identity" && $2 ~ /^[0-9a-f]{64}$/ {print $2; f=1} END {exit !f}' "${KYR_BUILD_ROOT_MARKER}"
}

kyr_root_release_check() {
    kyr_root_identity > /dev/null && return 0
    [[ "${KYR_ALLOW_HOST_BUILD:-0}" == 1 ]]
}

kyr_root_lib_ceiling() {
    kyr_root_identity > /dev/null || return 1
    local lib
    case "$1" in
        GLIBC) lib=libc.so.6 ;;
        GLIBCXX|CXXABI) lib=libstdc++.so.6 ;;
        GCC) lib=libgcc_s.so.1 ;;
        *) return 1 ;;
    esac
    lib="$(ls /lib/*-linux-gnu/"${lib}" /usr/lib/*-linux-gnu/"${lib}" 2> /dev/null | head -1)"
    [[ -n "${lib}" ]] || return 1
    readelf -VW "${lib}" 2> /dev/null | awk '/Version definition section/ {d=1; next} /Version (needs|symbols) section/ {d=0} d' |
        grep -oE "Name: $1_[0-9][0-9.]*" | sed 's/^Name: [A-Z]*_//' | sort -V | tail -1 | grep .
}
