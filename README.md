# kyr_build

The toolchain of the kyr platform (tier 0): one package, `kyr-build`, that every repository pins in `deps.txt` and never copies. Plus the header-only utilities as one deb per header.

## Packages

| Package | Installs | Notes |
|---|---|---|
| `kyr-build` (arch all) | `/usr/local/share/kyr-build/` | `gcc_build_profiles.sh`, `check_hardening.sh`, `deps.sh`, `vendor.sh`, `buildinfo.sh`, `build_root.sh`, `template_check.sh`, `tiers.txt`, `.clang-format`, `lib/deb.sh`, `lib/build.sh`, `lib/tier.sh`, `lib/epoch.sh`, `abi/` (`check_abi.sh`, `abi.py`), `template/` |
| `kyr-util-<header>` (arch all) | `/usr/local/include/kyr/util/<header>.h` and, until the next major, `/usr/local/include/utils/<header>.h` | Provides/Replaces `rh-util-<header>` |
| `rh-util-<header>` (arch all) | `/usr/local/include/utils/<header>.h` | the pre-2.0 name, still built so today's pins resolve |

Headers: `memory_macros.h`, `preprocessor_macros.h`, `string_view.h`, `time_macros.h` under `app/include/kyr/util/`.

## How a repository uses it

`deps.txt` carries `own kyr-build <ver> RomanHorshkov/Utils <sha256>`. The repository keeps four thin wrappers from `template/utils/` (`deps.sh`, `gcc_build_profiles.sh`, `check_hardening.sh`, `vendor.sh`); `utils/deps.sh` bootstraps the pinned deb by exact version and sha256 into `build/sysroot/share/kyr-build/` (no sudo, the Gradle-wrapper pattern), then `deps.sh sysroot` extracts every other pinned deb into `build/sysroot/` and prints the exports (`<NAME>_DEPS_INCLUDE_DIR`, `<NAME>_DEPS_LIB_DIR`, `KYR_BUILD_DIR`, `LD_LIBRARY_PATH`, `PKG_CONFIG_PATH`). Two repositories pin different versions of one library on one workstation.

```
./utils/deps.sh sysroot && eval "$(./utils/deps.sh env)" && ./utils/run_pipeline.sh
./utils/deps.sh check --tiers        # the tier law: a repository pins only lower tiers
./utils/gcc_build_profiles.sh explain
```

A new product (repository, descriptor, envs, rights, bundle, edition, platform line): `share/template/NEW_PRODUCT.md`.

Tiers (plan §2.1): a repository declares its own in the first line of `deps.txt`, `# tier: <n> <kind>` (build 0, foundation 1, platform 2, host 3, core 4, product 5, composition 6, platform-definition 7, fleet 8); `lib/deb.sh` writes it into every deb as `X-Kyr-Tier`; `check --tiers` refuses any pin that is not of a strictly lower tier, reading the pin's tier from its deb. `share/tiers.txt` lists only the platform's fixed repositories, as a cross-check and for debs built before the field existed; a repository it does not list can only be a product, so adding a product changes nothing here.

ABI gate (`share/abi/check_abi.sh`, lifted from DB_lmdb's `check_abi_layout.sh`, through the template's `utils/check_abi.sh`; pipeline stages `abi` and `abi-exports` when `abi/layout.txt` exists): the layout program is generated from the repository's public headers (a hand-written `abi/layout.c` is honoured and cross-checked), `abi/layout.txt` records every public struct's size, alignment and members, enumerator values, callbacks, function signatures, numeric `#define` constants and unnamed enums; SemVer against the newest reachable `v<x.y.z>` tag (else the previous commit), over the working tree and every commit that changed the file: a changed or removed line or a member added to an existing struct needs a raised major, a new public name a raised minor, a newly covered category nothing; `--exports` requires the library to export exactly the declared functions as `<name>@@<NODE>_<major>`. Needs gcc, readelf, python3 and full git history (`fetch-depth: 0`).

Per-project flags live in `utils/<name>_project.sh`, sourced after the catalog: `gcc_build_add`, `gcc_build_drop`, `gcc_build_replace`. The catalog is the default, never a law.

## Reproducible builds

The catalog fixes `umask 022`, exports `TZ=UTC` and `SOURCE_DATE_EPOCH` from the last commit that touched a build input (`lib/epoch.sh`: `app`, `VERSION`, `deps.txt`, `utils`, `debian` by default, extended by `KYR_BUILD_INPUTS+=(…)` in the project file; a caller's export wins), so a docs-, tests- or abi-only commit builds byte-identical debs, and puts `-ffile-prefix-map=<root>=.` and `-fdebug-prefix-map` in every profile; `GCC_BUILD_ARFLAGS` is `rcsD`. `lib/deb.sh` builds with `dpkg-deb --root-owner-group`, epoch-clamped mtimes and sorted tars (`deb_tar`), and writes one `<deb>.buildinfo` next to every deb (`buildinfo.sh`: hash, epoch, build-root hash, commit, flags, tool versions, pins). `build_root.sh` makes the pinned build root (`debootstrap` from `snapshot.ubuntu.com` at one date, hash recorded in `build/root.sha256`, entered with `unshare`/`chroot`); `create` and `hash` need root.

## This repository

`./utils/run_pipeline.sh`: every script parses, every header compiles as C11 and C++17, the debs build, then `tests/ITs/` prove from the built deb that a second build is byte-identical, that the template repository is green out of the box and builds the same deb from two directories, that the wrapper refuses a wrong sha256, and that the tier law holds from declarations alone (a new product passes untouched, a product pinning a product is refused), that a docs-only commit keeps the debs byte-identical, and that the ABI gate on a scratch library refuses every unversioned ABI change. `./utils/build_deb.sh` alone writes `build/debs/` with `SHA256SUMS`.

Release: master green, signed tag `v<VERSION>`, `release.yml` (cicd `c-release`, double build on two runners). Consumers pin the new version with the sha256 from `SHA256SUMS`.

Diagrams: `docs/diagrams/kyr_build_components.puml` (what ships), `docs/diagrams/sysroot_bootstrap_sequence.puml` (how a repository resolves it), `docs/diagrams/tier_check.puml` (where a tier comes from), `docs/diagrams/abi_gate.puml` (what an ABI change needs). `docs/compilation_steps.md` is the flag-stage reference.
