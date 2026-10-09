#!/usr/bin/env bash
# tls_ca.sh from the built deb: a CA and a leaf for two hosts under the deterministic names, keys 0600, the chain verified, a
# second mint a no-op, nothing written outside the directory; one-shot openssl s_servers on loopback answer curl, Python and
# openssl s_client under trust-env and refuse curl without it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
TLS="${SCRATCH}/kb/usr/local/share/kyr-build/tls_ca.sh"
[[ -x "${TLS}" ]] || fail "tls_ca.sh not shipped executable"
mkdir -p "${SCRATCH}/cwd" "${SCRATCH}/home"; cd "${SCRATCH}/cwd"
HOME="${SCRATCH}/home" "${TLS}" mint "${SCRATCH}/ca" it.example.test alt.example.test > /dev/null
[[ -z "$(ls -A "${SCRATCH}/cwd")" && -z "$(ls -A "${SCRATCH}/home")" ]] || fail "mint wrote outside <dir>"
D="${SCRATCH}/ca"
[[ "$(ls "${D}" | tr '\n' ' ')" == "ca.crt ca.key ca.srl it.example.test.crt it.example.test.fullchain.pem it.example.test.key " ]] || fail "names: $(ls "${D}" | tr '\n' ' ')"
[[ "$(stat -c %a "${D}/ca.key")" == 600 && "$(stat -c %a "${D}/it.example.test.key")" == 600 ]] || fail "keys are not 0600"
openssl verify -CAfile "${D}/ca.crt" "${D}/it.example.test.crt" > /dev/null || fail "the leaf does not verify against the CA"
for h in it.example.test alt.example.test; do has 'does match' openssl x509 -in "${D}/it.example.test.crt" -noout -checkhost "${h}" || fail "SAN lacks ${h}"; done
has 'does match' openssl x509 -in "${D}/it.example.test.crt" -noout -checkip 127.0.0.1 || fail "SAN lacks 127.0.0.1"
has 'does match' openssl x509 -in "${D}/it.example.test.crt" -noout -checkip ::1 || fail "SAN lacks ::1"
has 'does match' openssl x509 -in "${D}/it.example.test.crt" -noout -checkhost other.test && fail "SAN covers a host it was not minted for"
[[ "$(openssl x509 -in "${D}/ca.crt" -noout -enddate | sed 's/notAfter=//' | xargs -I{} date -d {} +%s)" -gt $(( $(date +%s) + 360 * 86400 )) ]] || fail "the CA is not good for a year"
[[ "$(grep -c 'BEGIN CERTIFICATE' "${D}/it.example.test.fullchain.pem")" == 2 ]] || fail "fullchain holds $(grep -c 'BEGIN CERTIFICATE' "${D}/it.example.test.fullchain.pem") certificates"
sha256sum "${D}"/* > "${SCRATCH}/before"
has '(kept)' "${TLS}" mint "${D}" it.example.test alt.example.test || fail "a second mint did not keep the leaf"
sha256sum "${D}"/* | cmp -s - "${SCRATCH}/before" || fail "a second mint changed a file"
has 'minted' "${TLS}" mint "${D}" it.example.test new.example.test || fail "a host the leaf lacks did not re-mint it"
cmp -s <(sed -n '/ca\.\(crt\|key\)$/p' "${SCRATCH}/before") <(sha256sum "${D}"/ca.crt "${D}"/ca.key) || fail "re-minting the leaf touched the CA"
has 'not a host name' "${TLS}" mint "${D}" 'bad host' || fail "a bad host name was accepted"

port() { printf '%d' $(( (RANDOM % 20000) + 30000 )); }
# serve <port> <naccept>: a one-shot openssl s_server on loopback answering a page; waits until it listens
serve() {
    openssl s_server -accept "127.0.0.1:$1" -naccept "$2" -cert "${D}/it.example.test.fullchain.pem" -key "${D}/it.example.test.key" -www > "${SCRATCH}/s_server.$1.log" 2>&1 &
    SRV=$!
    # s_server prints ACCEPT once it listens: no ss or netstat needed (the build root has neither)
    for _ in $(seq 50); do grep -q '^ACCEPT' "${SCRATCH}/s_server.$1.log" 2> /dev/null && return 0; sleep 0.1; done
    return 1
}
unset SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE KYR_TLS_CA
P="$(port)"; serve "${P}" 1 || fail "s_server did not start"
has 'certificate' curl -sS --resolve "it.example.test:${P}:127.0.0.1" "https://it.example.test:${P}/" && printf 'curl refuses the test CA until trust-env\n' || fail "curl trusted the CA without trust-env"
kill "${SRV}" 2> /dev/null || true; wait "${SRV}" 2> /dev/null || true
eval "$("${TLS}" trust-env "${D}")"
[[ "${SSL_CERT_FILE}" == "${D}/ca.crt" && "${CURL_CA_BUNDLE}" == "${D}/ca.crt" && "${REQUESTS_CA_BUNDLE}" == "${D}/ca.crt" && "${KYR_TLS_CA}" == "${D}/ca.crt" ]] || fail "trust-env exports"
P="$(port)"; serve "${P}" 1 || fail "s_server did not start"
curl -sS --resolve "it.example.test:${P}:127.0.0.1" "https://it.example.test:${P}/" | grep -q 'Ciphers supported' || fail "curl under trust-env could not fetch the s_server page"
wait "${SRV}" 2> /dev/null || true
P="$(port)"; serve "${P}" 1 || fail "s_server did not start"
has 'Verify return code: 0 (ok)' openssl s_client -connect "127.0.0.1:${P}" -servername it.example.test -verify_return_error < /dev/null || fail "openssl s_client under trust-env does not verify"
wait "${SRV}" 2> /dev/null || true
P="$(port)"; serve "${P}" 1 || fail "s_server did not start"
python3 - "${P}" <<'PY' || fail "Python under trust-env could not fetch the s_server page"
import ssl, sys, http.client
c = http.client.HTTPSConnection("127.0.0.1", int(sys.argv[1]), context=ssl.create_default_context())
c.request("GET", "/"); r = c.getresponse()
sys.exit(0 if r.status == 200 and b"Ciphers supported" in r.read() else 1)
PY
wait "${SRV}" 2> /dev/null || true
printf 'tls_ca.sh: chain, names, modes, idempotence, s_server under trust-env ok\n'
