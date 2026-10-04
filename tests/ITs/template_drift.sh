#!/usr/bin/env bash
# template_check reports drift instead of passing it: the template is clean; a changed wrapper, an undeclared script in utils/,
# a project file with a function or a compiler call, a .clang-format without its final newline and a copied machinery
# directory are each DRIFT; a gate listed in KYR_REPO_GATES is accepted; C outside app/ still makes a C repository; a repository
# with no C keeps only utils/deps.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
TC=build/sysroot/share/kyr-build/template_check.sh
g() { git -c user.name=it -c user.email=it@localhost "$@" > /dev/null; }
clean() { g checkout -q -- .; git clean -qfd -e build; }
drift() {  # <pattern> <what>
    local out rc=0
    out="$("${TC}" . 2>&1)" || rc=$?
    (( rc )) && grep -q -- "$1" <<< "${out}" && grep -q 'template: drift found' <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "$2"; }
    clean
}
"${TC}" . > "${SCRATCH}/clean.log" || { cat "${SCRATCH}/clean.log"; fail "the template drifts from itself"; }

printf '# local tweak\n' >> utils/build_libs.sh
drift 'DRIFT   utils/build_libs.sh differs from the kyr-build wrapper' "a changed wrapper"
printf '#!/usr/bin/env bash\ngcc -c x.c\n' > utils/build_extra.sh
drift 'DRIFT   utils/build_extra.sh is neither' "an undeclared build script"
mkdir -p utils/OLD; printf 'old\n' > utils/OLD/build_libs.sh
drift 'DRIFT   utils/OLD/build_libs.sh' "a machinery directory"
printf 'kyr_word_sources() { find app -name "*.c"; }\n' >> utils/kyr_word_project.sh
drift 'defines functions' "a function in the project file"
printf 'gcc -c app/src/word.c\n' >> utils/kyr_word_project.sh
drift 'calls a compiler or packager' "a compiler call in the project file"
printf '%s' "$(cat .clang-format)" > .clang-format
drift '.clang-format does not end with a newline' "a .clang-format without its final newline"
rm utils/run_pipeline.sh
"${TC}" . > /dev/null || fail "a wrapper the repository does not use is not required"
clean

printf '#!/usr/bin/env bash\nexit 0\n' > utils/check_word.sh; mkdir -p utils/lib; printf 'x=1\n' > utils/lib/parse.sh
printf 'KYR_REPO_GATES=(check_word.sh lib)\n' >> utils/kyr_word_project.sh
out="$("${TC}" .)" || { printf '%s\n' "${out}"; fail "declared gates refused"; }
grep -q 'ok      utils/check_word.sh (repository gate, KYR_REPO_GATES)' <<< "${out}" && grep -q 'utils/lib/parse.sh (repository gate' <<< "${out}" \
    || fail "gates not reported"
clean

# C outside app/: still a C repository, so quality.yml is required.
mkdir -p tools; printf 'int main(void) { return 0; }\n' > tools/gen.c; rm -rf app .github/workflows/quality.yml
drift 'MISSING .github/workflows/quality.yml' "C outside app/ treated as no C"

# No C at all: only utils/deps.sh is required.
N="${SCRATCH}/kyr_web"; mkdir -p "${N}/utils"
cp utils/deps.sh "${N}/utils/"; cp VERSION deps.txt LICENSE README.md "${N}/"
"${TC}" "${N}" > "${SCRATCH}/noc.log" || { cat "${SCRATCH}/noc.log"; fail "a repository without C"; }
grep -q 'no C sources' "${SCRATCH}/noc.log" || fail "no-C note"
