#!/usr/bin/env bash
# SOURCE_DATE_EPOCH is the commit time of the last commit that touched a build input (lib/epoch.sh): a commit touching only
# docs, tests, abi/ or the README leaves every deb byte-identical, a source commit changes them, a project file can add an
# input, and an epoch the caller exported wins.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
commit_at() { # <epoch> <message>: commit everything with that author and committer time
    git add -A
    GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000" git -c user.name=it -c user.email=it@localhost commit -q -m "$2"
}
debs() { ./utils/build_deb.sh > /dev/null && sed 's| .*/| |' build/debs/SHA256SUMS; }
epoch_of_build() { awk '$1=="Source-Date-Epoch:" {print $2; exit}' build/debs/libkyr-word_0.1.0_*.deb.buildinfo; }

printf '/* the word library */\n' >> app/src/word.c
commit_at 1800000000 "source"
base="$(debs)"
[[ "$(epoch_of_build)" == 1800000000 ]] || fail "epoch of the source commit"

mkdir -p docs abi
printf 'A note.\n' >> README.md
printf "' a note\n" >> docs/diagrams/word_components.puml
printf '/* a note */\n' >> tests/UTs/word_tests.c
printf 'major 0\n' > abi/layout.txt
commit_at 1800000100 "docs, tests and abi only"
[[ "$(debs)" == "${base}" ]] || fail "a docs, tests and abi commit changed the debs"
[[ "$(epoch_of_build)" == 1800000000 ]] || fail "a docs commit moved the epoch"

printf '/* a change */\n' >> app/src/word.c
commit_at 1800000200 "source again"
[[ "$(debs)" != "${base}" ]] || fail "a source commit left the debs unchanged"
[[ "$(epoch_of_build)" == 1800000200 ]] || fail "epoch of the second source commit"

for input in VERSION deps.txt utils/build_deb.sh debian/copyright; do
    printf '\n' >> "${input}"
    t=$(( $(epoch_of_build) + 100 ))
    commit_at "${t}" "input ${input}"
    debs > /dev/null
    [[ "$(epoch_of_build)" == "${t}" ]] || fail "${input} is not a build input"
done

mkdir -p web
printf 'export default {};\n' > web/x.js
commit_at 1800001000 "web tree, not an input yet"
debs > /dev/null
[[ "$(epoch_of_build)" != 1800001000 ]] || fail "web/ is an input before the project file says so"
printf 'KYR_BUILD_INPUTS+=(web)\n' >> utils/kyr_word_project.sh
commit_at 1800001100 "the project file adds web/"
printf '// changed\n' >> web/x.js
commit_at 1800001200 "web only"
debs > /dev/null
[[ "$(epoch_of_build)" == 1800001200 ]] || fail "an input added by the project file is ignored"

SOURCE_DATE_EPOCH=1234567890 ./utils/build_deb.sh > /dev/null
[[ "$(epoch_of_build)" == 1234567890 ]] || fail "an exported SOURCE_DATE_EPOCH does not win"
