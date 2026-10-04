# kyr_build

The toolchain of the kyr platform (tier 0): one package, `kyr-build`, that every repository pins in `deps.txt` and never copies. Plus the header-only utilities as one deb per header.

## Packages

| Package | Installs | Notes |
|---|---|---|
| `kyr-build` (arch all) | `/usr/local/share/kyr-build/` | `gcc_build_profiles.sh`, `check_hardening.sh`, `deps.sh`, `vendor.sh`, `format.sh`, `pipeline.sh`, `check_reproducible.sh`, `coverage_badge.py`, `buildinfo.sh`, `build_root.sh`, `template_check.sh`, `tiers.txt`, `.clang-format`, `lib/` (`kyr.sh`, `build.sh`, `test.sh`, `deb.sh`, `tier.sh`, `epoch.sh`, `root.sh`), `abi/` (`check_abi.sh`, `abi.py`), `wrappers/`, `template/` |
| `kyr-util-<header>` (arch all) | `/usr/local/include/kyr/util/<header>.h` and, until the next major, `/usr/local/include/utils/<header>.h` | Provides/Replaces `rh-util-<header>` |
| `rh-util-<header>` (arch all) | `/usr/local/include/utils/<header>.h` | the pre-2.0 name, still built so today's pins resolve |

Headers: `memory_macros.h`, `preprocessor_macros.h`, `string_view.h`, `time_macros.h` under `app/include/kyr/util/`.

## How a repository uses it

`deps.txt` carries `own kyr-build <ver> RomanHorshkov/kyr_build <sha256>`. `utils/deps.sh` bootstraps the pinned deb by exact version and sha256 into `build/sysroot/share/kyr-build/` (no sudo, the Gradle-wrapper pattern), then `deps.sh sysroot` extracts every other pinned deb into `build/sysroot/` and prints the exports (`<NAME>_DEPS_INCLUDE_DIR`, `<NAME>_DEPS_LIB_DIR`, `KYR_BUILD_DIR`, `LD_LIBRARY_PATH`, `PKG_CONFIG_PATH`). Two repositories pin different versions of one library on one workstation.

```
./utils/deps.sh sysroot && eval "$(./utils/deps.sh env)" && ./utils/run_pipeline.sh
./utils/deps.sh check --tiers        # the tier law: a repository pins only lower tiers
./utils/deps.sh manifest-verify      # every cached deb against its pin and its release's SHA256SUMS (--strict: no unreleased pin)
./utils/gcc_build_profiles.sh explain
```

The cache is `$KYR_DEPS_CACHE`, else `$RH_DEPS_CACHE`, else `~/.cache/rh-deps` (`debs/`, `sums/`, `vendor/`). A pin may carry `optional` (resolved only with `--with-optional`), `test` (the tests need it) or `static` (linked or composed at build time): none becomes a runtime `Depends`.

## Wrapper contract

A repository's `utils/` holds only: kyr-build's wrappers (`share/wrappers/`, byte-identical), its project file `utils/<name>_project.sh` (declarations only, no function, no compiler call), linker maps `utils/*.map`, and the repository gates its project file lists in `KYR_REPO_GATES`. `template_check.sh` reports anything else as drift (CI's template stage). Each wrapper sources the catalog and `lib/kyr.sh` (the project file, `lib/build.sh`, `lib/test.sh`, `lib/deb.sh`) and makes one call:

| Wrapper | Share entry | Replaces |
|---|---|---|
| `deps.sh` | bootstrap, then `deps.sh` | per-repo deps scripts, kyr's fork (`manifest-verify`) |
| `gcc_build_profiles.sh`, `check_hardening.sh`, `check_abi.sh`, `vendor.sh`, `format.sh`, `check_reproducible.sh` | the share script of that name | copies of the catalog, gate, formatter, reproducibility check |
| `build_libs.sh [profile ...]` | `kyr_build_libs` | bespoke library builders (one object set, map-major check, vendored `-w`) |
| `build_bin.sh [profile]` | `kyr_build_bin` (`KYR_BINS`) | per-repo binary builders, demo and test apps |
| `build_tests.sh`, `run_tests.sh [profile]` | `kyr_build_tests`, `kyr_run_tests` | per-profile test builders and runners (support sources, shared variant, expected failure, env, reset) |
| `coverage.sh` | `kyr_coverage` | coverage.sh, release_cov builds, gcovr scripts |
| `build_fuzz.sh`, `run_fuzz_smoke.sh [s]` | `kyr_fuzz_build`, `kyr_fuzz_smoke` | per-repo libFuzzer and standalone fuzz scripts |
| `run_ITs.sh` | `kyr_run_it_scripts` (`KYR_IT_SCRIPTS`, exit 77 skips) | IT runners |
| `build_UTs.sh`, `build_UTs_release.sh` | `kyr_ut_coverage`, `kyr_ut_release` | unit suite builders with gcovr gates |
| `build_ITs.sh` | `kyr_its` (profile x linkage cells, coverage) | integration matrices, `run_ITs.sh` of the foundation |
| `build_sanitizer_tests.sh`, `build_tsan_tests.sh` | `kyr_sanitize`, `kyr_tsan` | sanitizer scripts |
| `build_stress.sh`, `run_stress.sh`, `run_benchmarks.sh` | `kyr_stress_build`, `kyr_stress_run` | stress matrices and benchmark runners |
| `smoke_test_package.sh` | `kyr_smoke_package` (`tests/package/smoke.c`) | installed-package smoke scripts |
| `build_deb.sh` | `kyr_debs` (`KYR_DEBS`: `lib`, `lib-combined`, `bin:<pkg>`, `web:<pkg>`) | per-repo packaging (headers spec, `.pc`, Depends, payload guards) |
| `run_pipeline.sh` | `pipeline.sh` | per-repo pipelines |

`pipeline.sh` runs a stage when the repository has its wrapper (the detection cicd's `c-quality.yml` makes): deps-tiers, template, format (with the pinned clang-format major, else SKIP), vendor, abi, every build profile, abi-exports, the suites, per-profile tests, coverage, ITs, fuzz-smoke, benchmarks, package, package-smoke (the smoke test against the built debs extracted into `build/smoke`), reproducible. The extra-stage hook: `KYR_PIPELINE_EXTRA=("<checks|build|tests|post>|<label>|<command>")` in the project file, e.g. `"checks|core-neutral|./utils/check_core_neutral.sh"` with the gate in `KYR_REPO_GATES`. The declarations each entry reads are listed at the top of `lib/build.sh`, `lib/test.sh`, `lib/deb.sh` and `pipeline.sh`. A badge workflow runs `build/sysroot/share/kyr-build/coverage_badge.py` after `./utils/deps.sh apt-list` (the bootstrap alone).

A new product (repository, descriptor, envs, rights, bundle, edition, platform line): `share/template/NEW_PRODUCT.md`.

Tiers (plan §2.1): a repository declares its own in the first line of `deps.txt`, `# tier: <n> <kind>` (build 0, foundation 1, platform 2, host 3, core 4, product 5, composition 6, platform-definition 7, fleet 8); `lib/deb.sh` writes it into every deb as `X-Kyr-Tier`; `check --tiers` refuses any pin that is not of a strictly lower tier, reading the pin's tier from its deb. `share/tiers.txt` lists only the platform's fixed repositories, as a cross-check and for debs built before the field existed; a repository it does not list can only be a product, so adding a product changes nothing here.

ABI gate (`share/abi/check_abi.sh`, lifted from DB_lmdb's `check_abi_layout.sh`, through the template's `utils/check_abi.sh`; pipeline stages `abi` and `abi-exports` when `abi/layout.txt` exists): the layout program is generated from the repository's public headers (a hand-written `abi/layout.c` is honoured and cross-checked), `abi/layout.txt` records every public struct's size, alignment and members (a function-pointer member with its full signature, so a hand-written `abi/layout.c` is not needed for it), enumerator values, callbacks, function signatures, numeric `#define` constants and unnamed enums; SemVer against the newest reachable `v<x.y.z>` tag (else the previous commit), over the working tree and every commit that changed the file: a changed or removed line or a member added to an existing struct needs a raised major, a new public name or a `*_ABI_MINOR` constant that only rose a raised minor, a newly covered category nothing; `--exports` requires the library to export exactly the declared functions as `<name>@@<NODE>_<major>`. The type, function and constant prefixes (`KYR_ABI_TYPE_PREFIX`, `KYR_ABI_FUNC_PREFIX`, `KYR_ABI_CONST_PREFIX`) are lists for a library with several namespaces. Needs gcc, readelf, python3 and full git history (`fetch-depth: 0`).

Per-project flags live in `utils/<name>_project.sh`, sourced after the catalog: `gcc_build_add`, `gcc_build_drop`, `gcc_build_replace`. The catalog is the default, never a law.

## Reproducible builds

The catalog fixes `umask 022`, exports `TZ=UTC` and `SOURCE_DATE_EPOCH` from the last commit that touched a build input (`lib/epoch.sh`: `app`, `VERSION`, `deps.txt`, `utils`, `debian` by default, extended by `KYR_BUILD_INPUTS+=(…)` in the project file; a caller's export wins), so a docs-, tests- or abi-only commit builds byte-identical debs, and puts `-ffile-prefix-map=<root>=.` and `-fdebug-prefix-map` in every profile; `GCC_BUILD_ARFLAGS` is `rcsD`. `lib/deb.sh` builds with `dpkg-deb --root-owner-group`, epoch-clamped mtimes and sorted tars (`deb_tar`), and writes one `<deb>.buildinfo` next to every deb (`buildinfo.sh`: hash, epoch, build-root identity, commit, flags, tool versions, pins).

## Build root

Every release is built inside the pinned build root (D48): Ubuntu Base 24.04 (`ubuntu-base-24.04.5-base-amd64.tar.gz`, sha256 pinned) with apt on `snapshot.ubuntu.com` at `20260901T000000Z`, made and entered rootless through `bwrap` (no sudo, no debootstrap). The host's toolchain is for development only.

```
share/build_root.sh create                          # ~/.cache/kyr-build-root/noble-20260901T000000Z and its .id record
share/build_root.sh show                            # pins, identity, files hash, gcc/libc/binutils versions inside
share/build_root.sh verify                          # identity (dpkg-query inside) and files hash against the record
share/build_root.sh enter -- ./utils/build_deb.sh   # run from a repository: it is /src
```

A repository reaches it as `build/sysroot/share/kyr-build/build_root.sh`. `enter` mounts the root read-only, binds the repository at `/src` (the working directory) and the deb cache read-write at the path the tools use, gives a throwaway `HOME`, shares the network (`--offline` drops it), refuses a root whose package set drifted, and passes only a short list of variables (`KYR_BUILD_ROOT_ENV` adds names). `--dir` moves the root.

The identity is the sha256 of suite, snapshot, tarball sha256 and the installed package list; it lives in the root as `/etc/kyr-build-root`. Every deb built inside records it as `Build-Root:` in its buildinfo; a host build records `none`. `build_deb` refuses a release outside the root unless `KYR_ALLOW_HOST_BUILD=1` (a development deb); both pipelines set it on the host, so builds and tests run there freely.

Glibc ceiling: `check_hardening.sh` refuses an ELF that needs a symbol version newer than the target has: `GLIBC_2.39`, `GLIBCXX_3.4.33`, `CXXABI_1.3.15`, `GCC_14.0.0`, `GLIBC_PRIVATE` never (noble; inside the root, its own libraries' versions). `KYR_TARGET_GLIBC_MAX`, `KYR_TARGET_GLIBCXX_MAX`, `KYR_TARGET_CXXABI_MAX`, `KYR_TARGET_GCC_MAX` raise it deliberately. The pipeline's `glibc-ceiling` stage runs `check_hardening.sh --ceiling-only` over every ELF under `build/`, whatever the profile.

## This repository

`./utils/run_pipeline.sh`: every script parses, the template's wrappers are the catalog's, every header compiles as C11 and C++17, the debs build, then `tests/ITs/` prove from the built deb that a second build is byte-identical, that the template repository is green out of the box and builds the same deb from two directories, that the wrapper refuses a wrong sha256 and honours both cache variables, that the tier law holds from declarations alone (a new product passes untouched, a product pinning a product is refused), that a docs-only commit keeps the debs byte-identical, that the ABI gate on a scratch library refuses every unversioned ABI change, that the suite wrappers, several targets and every packaging recipe work from declarations alone (`suites.sh`, `targets.sh`, `debs.sh`), that `template_check` reports drift (`template_drift.sh`), that `manifest-verify` tells released, unreleased and wrong pins apart, that the hardening allow-list takes `libkyr_*`, that the glibc ceiling refuses an executable bound by `.symver` to `GLIBC_2.40` (`glibc_ceiling.sh`), that `build_deb` refuses a host release without `KYR_ALLOW_HOST_BUILD=1` and records the root's identity inside it (`host_release.sh`), that `check_reproducible` compares two host builds on the host and two root builds inside a root, its clone refusing a host release without `KYR_ALLOW_HOST_BUILD=1` (`reproducible_host.sh`), and that the shipped `.clang-format` sorts `<cmocka.h>` after the C headers it needs (`format_includes.sh`). `share/build_root.sh enter -- ./utils/build_deb.sh` writes the release into `build/debs/` with `SHA256SUMS`.

Release: master green, signed tag `v<VERSION>`, `release.yml` (cicd `c-release`, double build on two runners; its `build_deb` refuses until the job enters the build root). Consumers pin the new version with the sha256 from `SHA256SUMS`.

Diagrams: `docs/diagrams/kyr_build_components.puml` (what ships), `docs/diagrams/sysroot_bootstrap_sequence.puml` (how a repository resolves it), `docs/diagrams/tier_check.puml` (where a tier comes from), `docs/diagrams/abi_gate.puml` (what an ABI change needs), `docs/diagrams/wrapper_contract.puml` (what a repository's utils/ may hold). `docs/compilation_steps.md` is the flag-stage reference.
