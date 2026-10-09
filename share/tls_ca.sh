#!/usr/bin/env bash
# tls_ca.sh — a test certificate authority for the gates, with openssl alone: a CA and one leaf for the hosts named, under
# deterministic names, never a byte outside <dir>; and the exports that make the tools of the calling shell trust it. P-256
# throughout (every browser, curl, nginx and gjs accept it; Ed25519 leaves Chrome out), one year.
#
#   tls_ca.sh mint <dir> <host> [<host>…]   ca.crt, ca.key, <host>.crt, <host>.key, <host>.fullchain.pem (the first host names the
#                                           files; the SANs are every host, 127.0.0.1 and ::1); keys 0600; a second run changes
#                                           nothing while the leaf covers the hosts and verifies against the CA (ca.srl: the serials)
#   tls_ca.sh trust-env <dir>               the export lines for `eval`: openssl (SSL_CERT_FILE), curl (CURL_CA_BUNDLE), Python
#                                           (SSL_CERT_FILE, REQUESTS_CA_BUNDLE); gjs/libsoup read no variable, so KYR_TLS_CA names
#                                           the file a check feeds Gio.TlsFileDatabase
set -euo pipefail
die() { printf 'tls_ca.sh: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
command -v openssl > /dev/null 2>&1 || die "openssl is not installed"

# leaf_covers <dir> <leaf> <host…>: the leaf verifies against the CA, is not expired and names every host and both addresses
leaf_covers() {
    local dir="$1" leaf="$2" h; shift 2
    openssl verify -CAfile "${dir}/ca.crt" "${leaf}" > /dev/null 2>&1 || return 1
    for h in "$@"; do openssl x509 -in "${leaf}" -noout -checkhost "${h}" 2> /dev/null | grep -q 'does match' || return 1; done
    openssl x509 -in "${leaf}" -noout -checkip 127.0.0.1 2> /dev/null | grep -q 'does match' || return 1
    openssl x509 -in "${leaf}" -noout -checkip ::1 2> /dev/null | grep -q 'does match'
}

mint() {
    local dir="$1" h ext san="" leaf key csr tmp; shift
    (( $# )) || usage
    for h in "$@"; do [[ "${h}" =~ ^[A-Za-z0-9*][A-Za-z0-9.*-]*$ ]] || die "not a host name: ${h}"; san+="DNS:${h},"; done
    san+="IP:127.0.0.1,IP:::1"
    mkdir -p "${dir}"; dir="$(cd "${dir}" && pwd)"
    leaf="${dir}/$1.crt"; key="${dir}/$1.key"; csr="${dir}/.$1.csr.tmp"; ext="${dir}/.ext.tmp"
    umask 077
    if [[ ! -s "${dir}/ca.crt" || ! -s "${dir}/ca.key" ]]; then
        rm -f "${dir}/ca.crt" "${dir}/ca.key" "${dir}/ca.srl"
        openssl ecparam -name prime256v1 -genkey -noout -out "${dir}/ca.key"
        openssl req -x509 -new -key "${dir}/ca.key" -sha256 -days 365 -subj '/CN=kyr test CA' \
            -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash' \
            -out "${dir}/ca.crt" 2> /dev/null
        chmod 0644 "${dir}/ca.crt"
    fi
    if [[ -s "${leaf}" && -s "${key}" ]] && leaf_covers "${dir}" "${leaf}" "$@"; then
        printf '%s/%s.crt covers %s (kept)\n' "${dir}" "$1" "$*"
    else
        tmp="${dir}/.$1.key.tmp"
        openssl ecparam -name prime256v1 -genkey -noout -out "${tmp}"
        openssl req -new -key "${tmp}" -subj "/CN=$1" -out "${csr}" 2> /dev/null
        printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' "${san}" > "${ext}"
        openssl x509 -req -in "${csr}" -CA "${dir}/ca.crt" -CAkey "${dir}/ca.key" -CAserial "${dir}/ca.srl" -CAcreateserial -days 365 -sha256 \
            -extfile "${ext}" -out "${leaf}.tmp" 2> /dev/null
        rm -f "${csr}" "${ext}"
        mv -f "${tmp}" "${key}"; mv -f "${leaf}.tmp" "${leaf}"; chmod 0644 "${leaf}"
        printf '%s/%s.crt minted for %s\n' "${dir}" "$1" "$*"
    fi
    cat "${leaf}" "${dir}/ca.crt" > "${dir}/$1.fullchain.pem.tmp"; mv -f "${dir}/$1.fullchain.pem.tmp" "${dir}/$1.fullchain.pem"; chmod 0644 "${dir}/$1.fullchain.pem"
    chmod 0600 "${dir}/ca.key" "${key}"
}

trust_env() {
    local dir ca
    dir="$(cd "$1" 2> /dev/null && pwd)" || die "no such directory: $1"
    ca="${dir}/ca.crt"; [[ -s "${ca}" ]] || die "no CA in ${dir}: tls_ca.sh mint first"
    printf 'export SSL_CERT_FILE=%q\n' "${ca}"
    printf 'export CURL_CA_BUNDLE=%q\n' "${ca}"
    printf 'export REQUESTS_CA_BUNDLE=%q\n' "${ca}"
    printf 'export KYR_TLS_CA=%q\n' "${ca}"
}

case "${1:-}" in
    mint) shift; (( $# >= 2 )) || usage; mint "$@" ;;
    trust-env) [[ $# == 2 ]] || usage; trust_env "$2" ;;
    *) usage ;;
esac
