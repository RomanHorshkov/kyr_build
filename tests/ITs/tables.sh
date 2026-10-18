#!/usr/bin/env bash
# The tables gate from the built deb (check_tables.sh, check_tables.py) on a scratch repository whose one .def is right by every
# rule: it passes; each rule's violation, planted in a copy, is refused with its rule (R1 signature, arity, an undescribed column,
# a wrong stated count; R2a a missing or misnamed sentinel; R2b no assert; R2c a hand array sized by the sentinel; R2d an
# unasserted const table; R3 no test reaching a reason table; R4 a repeated key and a repeated label; R5 a removed append-only row
# without a raised major); R6 is reported and does not fail; tables.allow keeps a reviewed site and refuses an entry without a
# reason or one that keeps nothing; KYR_TABLES_WARN=1 reports and exits 0.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
CHECK="${SCRATCH}/kb/usr/local/share/kyr-build/check_tables.sh"
[[ -x "${CHECK}" ]] || fail "kyr-build lacks check_tables.sh"

G="${SCRATCH}/good"; mkdir -p "${G}/app/include/kyr/zz" "${G}/app/src" "${G}/tests"
cat > "${G}/app/include/kyr/zz/reasons.def" <<'EOF'
/**
 * @file reasons.def
 * @brief Every refusal reason of the zz module, one row each; append-only wire tokens.
 *
 * X(_name, _token, _status)
 *   _name    the enum suffix, KYR_ZZ_REASON_<_name>
 *   _token   the wire token, unique
 *   _status  the HTTP status the refusal answers
 */
X(BAD_BODY, "bad_body", 400)
X(NOT_FOUND, "not_found", 404)
X(BUSY, "busy", 503)
EOF
cat > "${G}/app/include/kyr/zz/reasons.h" <<'EOF'
#ifndef KYR_ZZ_REASONS_H
#define KYR_ZZ_REASONS_H
typedef enum
{
#define X(_name, _token, _status) KYR_ZZ_REASON_##_name,
#include "kyr/zz/reasons.def"
#undef X
    KYR_ZZ_REASON_COUNT
} kyr_zz_reason_t;
const char* kyr_zz_reason_token(kyr_zz_reason_t r);
#endif
EOF
cat > "${G}/app/src/reasons.c" <<'EOF'
#include "kyr/zz/reasons.h"

static const char* const g_tokens[KYR_ZZ_REASON_COUNT] = {
#define X(_name, _token, _status) [KYR_ZZ_REASON_##_name] = _token,
#include "kyr/zz/reasons.def"
#undef X
};
_Static_assert(KYR_ZZ_REASON_COUNT <= 32, "a reason fits the 32-bit refusal mask");

static const unsigned g_primes[] = {2u, 3u, 5u};
_Static_assert(sizeof g_primes / sizeof g_primes[0] == 3u, "three primes");

const char* kyr_zz_reason_token(kyr_zz_reason_t r)
{
    return (unsigned)r < KYR_ZZ_REASON_COUNT ? g_tokens[r] : "server_error";
}

unsigned kyr_zz_prime(unsigned i)
{
    return i < 3u ? g_primes[i] : 0u;
}
EOF
cat > "${G}/tests/reasons_tests.c" <<'EOF'
#include <string.h>
#include "kyr/zz/reasons.h"

static const struct { kyr_zz_reason_t r; const char* token; } g_ledger[] = {
#define X(_name, _token, _status) {KYR_ZZ_REASON_##_name, _token},
#include "kyr/zz/reasons.def"
#undef X
};

int main(void)
{
    for(unsigned i = 0; i < sizeof g_ledger / sizeof g_ledger[0]; ++i)
        if(strcmp(kyr_zz_reason_token(g_ledger[i].r), g_ledger[i].token) != 0) return 1;
    return 0;
}
EOF
printf '0.1.0\n' > "${G}/VERSION"
( cd "${G}" && git init -q -b master && git add -A && git -c user.name=it -c user.email=it@localhost commit -q -m init )

run() { ( cd "$1" && "${CHECK}" "$1" ) > "${SCRATCH}/out" 2>&1; local rc=$?; cat "${SCRATCH}/out"; return "${rc}"; }
copy() { rm -rf "${SCRATCH}/c"; cp -a "${G}" "${SCRATCH}/c"; C="${SCRATCH}/c"; }
refused() { # <what> <text the output must hold>
    local out rc=0; out="$(run "${C}")" || rc=$?
    (( rc == 1 )) || { printf '%s\n' "${out}" >&2; fail "accepted (exit ${rc}): $1"; }
    grep -qF -- "$2" <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "refused without \"$2\": $1"; }
}
passes() { run "$2" > /dev/null || { cat "${SCRATCH}/out" >&2; fail "refused: $1"; }; }

# R5 first: the good repository records its append-only table, then it is clean.
copy; run "${C}" > /dev/null && fail "an unrecorded append-only table passed"
grep -qF 'R5: missing' "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "R5 without the missing record"; }
( cd "${G}" && "${CHECK}" "${G}" --update > /dev/null && git add -A && git -c user.name=it -c user.email=it@localhost commit -q -m tables )
grep -qx 'app/include/kyr/zz/reasons.def 1 NOT_FOUND "not_found"' "${G}/abi/tables.txt" || fail "abi/tables.txt lacks a row"
passes "the good repository" "${G}"

D="app/include/kyr/zz/reasons.def"; H="app/include/kyr/zz/reasons.h"; S="app/src/reasons.c"; T="tests/reasons_tests.c"
copy; sed -i '/^ \* X(_name, _token, _status)$/d' "${C}/${D}"; refused "no signature" "${D}:9: R1: no X(c1, c2, ...) signature"
copy; printf 'X(GONE, "gone")\n' >> "${C}/${D}"; refused "a row of another arity" "R1: signature X(_name, _token, _status) has 3 columns"
copy; sed -i '/_status  the HTTP status/d' "${C}/${D}"; refused "an undescribed column" "R1: column _status is not described"
copy; sed -i 's/one row each/the 4 reasons, one row each/' "${C}/${D}"; refused "a wrong stated count" "R1: the header says"
copy; sed -i 's/KYR_ZZ_REASON_COUNT$/KYR_ZZ_REASON_LAST/; s/KYR_ZZ_REASON_COUNT/KYR_ZZ_REASON_LAST/g' "${C}/${H}" "${C}/${S}"
refused "a sentinel not named _COUNT" "sentinel-name: the sentinel KYR_ZZ_REASON_LAST"
copy; sed -i '/KYR_ZZ_REASON_COUNT$/d' "${C}/${H}"; refused "no sentinel" "R2a: not expanded into an enum"
copy; sed -i '/fits the 32-bit refusal mask/d' "${C}/${S}"; refused "no assert on the count" "R2b: no _Static_assert names KYR_ZZ_REASON_COUNT"
copy; printf 'static const int g_status[KYR_ZZ_REASON_COUNT] = {400, 404, 503};\nint zz_s(int i) { return g_status[i]; }\n' >> "${C}/${S}"
refused "a hand array sized by the sentinel" "R2c: g_status[KYR_ZZ_REASON_COUNT] is initialized by hand"
copy; printf 'static const int g_more[] = {7, 11};\nint zz_m(int i) { return g_more[i]; }\n' >> "${C}/${S}"
refused "an unasserted const table" "R2d: g_more (2 rows) is named by no _Static_assert"
copy; printf 'int main(void) { return 0; }\n' > "${C}/${T}"; refused "a reason table no test expands" "R3: no test expands it"
copy; sed -i 's/^X(BUSY, "busy", 503)$/X(BUSY, "busy", 503)\nX(BUSY, "busier", 503)/' "${C}/${D}"; refused "a repeated key" "R4: _name repeats BUSY"
copy; sed -i 's/^X(BUSY, "busy", 503)$/X(BUSY, "busy", 503)\nX(SLOW, "busy", 503)/' "${C}/${D}"; refused "a repeated token" "R4: _token repeats \"busy\""
copy; sed -i '/^X(NOT_FOUND/d' "${C}/${D}"; ( cd "${C}" && "${CHECK}" "${C}" --update > /dev/null )
refused "a removed append-only row at the same major" "R5: changed or removed since HEAD without a raised major"
printf '1.0.0\n' > "${C}/VERSION"; passes "a removed append-only row with a raised major" "${C}"

copy; cat >> "${C}/${S}" <<'EOF'
int zz_class(int s)
{
    switch(s)
    {
        case 400: return 1;
        case 401: return 1;
        case 403: return 1;
        case 404: return 1;
        case 409: return 1;
        case 413: return 1;
        case 429: return 2;
        default: return 0;
    }
}
EOF
run "${C}" > /dev/null || { cat "${SCRATCH}/out" >&2; fail "an R6 report failed the stage"; }
grep -qF 'R6 (report): switch with 7 case labels in zz_class()' "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "R6 not reported"; }

copy; printf 'static const int g_more[] = {7, 11};\nint zz_m(int i) { return g_more[i]; }\n' >> "${C}/${S}"
printf '# reviewed\nallow %s:g_more R2d two literal constants, checked by zz_m_tests\n' "${S}" > "${C}/tables.allow"
passes "an allow entry with its reason" "${C}"
printf 'allow %s:g_gone R2d it went away\n' "${S}" >> "${C}/tables.allow"; refused "an entry that keeps nothing" "STALE   tables.allow:3:"
printf '# reviewed\nallow %s:g_more R2d\n' "${S}" > "${C}/tables.allow"; refused "an entry without a reason" "BAD     tables.allow:2:"
rm -f "${C}/tables.allow"; ( cd "${C}" && KYR_TABLES_WARN=1 "${CHECK}" "${C}" ) > "${SCRATCH}/out" 2>&1 || fail "KYR_TABLES_WARN=1 refused"
grep -qF 'KYR_TABLES_WARN=1: reported, not refused' "${SCRATCH}/out" || fail "KYR_TABLES_WARN=1 did not say it reported"
