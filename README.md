# rh-utils — header-only utilities, one Debian package per header

Small, dependency-free C headers shared across the DB platform repos. Each header is packaged as its **own** Debian package shipping a single `.h`, plus one `rh-utils-devtools` package for the shared build tooling.

## Headers → packages

| Header (`header_only/`)   | Package                        | Installs to                              | Consumed as                        |
|---------------------------|--------------------------------|------------------------------------------|------------------------------------|
| `string_view.h`           | `rh-util-string-view`          | `/usr/local/include/utils/string_view.h` | `#include <utils/string_view.h>`   |
| `memory_macros.h`         | `rh-util-memory-macros`        | `/usr/local/include/utils/memory_macros.h` | `#include <utils/memory_macros.h>` |
| `time_macros.h`           | `rh-util-time-macros`          | `/usr/local/include/utils/time_macros.h` | `#include <utils/time_macros.h>`   |
| `preprocessor_macros.h`   | `rh-util-preprocessor-macros`  | `/usr/local/include/utils/preprocessor_macros.h` | `#include <utils/preprocessor_macros.h>` |
| — (build tooling)         | `rh-utils-devtools`            | `/usr/local/share/rh-utils/{gcc_build_profiles.sh,check_hardening.sh,.clang-format,testkit/}` | tooling, not `#include`d |

The include path is **flat**: every header lands directly in `/usr/local/include/utils/`, so `#include <utils/<name>.h>` works unchanged. The package split is purely about *distribution* — a consumer depends only on the headers it actually includes, and each header can version independently.

## Why one package per header

- **Minimal dependencies.** DB_http includes only `<utils/memory_macros.h>` and `<utils/string_view.h>`; its deb depends on just those two packages, not on a monolith carrying headers it never uses.
- **Independent versioning.** Bumping `string_view.h` is a version bump of `rh-util-string-view` alone; unrelated consumers are untouched.
- **Clear ownership.** `dpkg -S /usr/local/include/utils/time_macros.h` names exactly one package.

## Build

```bash
bash compilation/build_deb.sh          # → build/debs/*.deb (5 packages)
```

The script discovers `header_only/*.h` automatically — **adding a header needs no script edit**; it becomes `rh-util-<name>` (underscores → hyphens) on the next build. Version comes from `VERSION` (currently `1.0.0`) and applies to every package it emits. Output lands in `build/debs/`.

Each package declares `Replaces:`/`Conflicts: rh-utils` (the retired monolithic package), so on a machine that still has the old `rh-utils`, `apt` removes it and the split packages take over its files with no conflict.

## Install

Installed as part of the platform bootstrap (`sudo ./dbctl install --vm|--release` at the superproject root), which builds and installs each repo's debs in dependency order. To install just these by hand:

```bash
sudo apt-get install --yes ./build/debs/rh-util-*_1.0.0_all.deb \
                           ./build/debs/rh-utils-devtools_1.0.0_all.deb
```

Verify:

```bash
dpkg -L rh-util-memory-macros            # → /usr/local/include/utils/memory_macros.h
echo '#include <utils/memory_macros.h>' | gcc -fsyntax-only -x c -   # compiles
```

## Build profiles & hardening — the canonical catalog

This repo is the **home** of the platform's build policy: `compilation/gcc_build_profiles.sh` (the flag catalog every repo syncs verbatim — per-flag cost/rationale is documented inline in that file) and `compilation/check_hardening.sh` (the readelf verifier that gates every release artifact). Both ship in `rh-utils-devtools` under `/usr/local/share/rh-utils/`. Changing a flag HERE changes it for the whole platform on the next profile sync.

The profile lineup:

| Profile | Optimization | Warnings | Instrumentation | Hardened | Use it for |
|---------|--------------|----------|-----------------|----------|------------|
| `debug` | `-Og -g3` | core | — | no | day-to-day development |
| `audit` | `-O1 -g3` | everything + `-fanalyzer` | — | yes | compiler-driven validation |
| `sanitize` | `-O1 -g3` | strict | ASan + UBSan + LSan | yes, minus FORTIFY (conflicts with ASan) | runtime bug hunting |
| `release` | `-O2 -DNDEBUG` | strict | — | yes — the full set below | production, the deb payload |
| `native` | `-O3 -flto -march=native` | strict | — | yes | benchmarks on the deploy box |
| `extreme` | `-O3 -flto -march=native` | core | — | deliberately none | max-perf experiments only |

Release hardening, by stage:

| Flag | Stage | What it does |
|------|-------|--------------|
| `-fstack-protector-strong` | compile | stack canary on frames with arrays / address-taken locals |
| `-fstack-clash-protection` | compile | stack grows page by page — the guard page can't be jumped over |
| `-fcf-protection=full` | compile | x86-64 CET: indirect-branch tracking + shadow stack (NOP on older CPUs) |
| `-fno-common` | compile | duplicate tentative globals become link errors |
| `-D_FORTIFY_SOURCE=3` | preprocess | checked libc calls (`memcpy`, `snprintf`, …) with dynamic object sizes |
| `-fPIC` / `-fPIE` | compile | position-independent code (libraries / executables) |
| `-Wl,-z,relro -Wl,-z,now` | link (`.so` + exe) | GOT/PLT read-only after load — full RELRO |
| `-Wl,-z,noexecstack` | link | non-executable stack, asserted |
| `-Wl,-z,defs` | link (`.so`) | undefined symbols fail the build, not the load on the box |
| `-Wl,--as-needed` | link (`.so`) | only real dependencies recorded as NEEDED |
| `-pie` | link (exe) | ASLR randomizes the executable image itself |

Two rules with teeth:

- **The two link policies never mix.** Profile LDFLAGS contain `-pie`; in a `gcc -shared` link that makes the driver link an executable image and the build FAILS. Shared links take `LDFLAGS_SHARED`, executables take the profile LDFLAGS.
- **Artifacts are verified, not trusted.** `check_hardening.sh` asserts PIE / full RELRO / non-exec stack / no TEXTREL (hard, exit 2) and reports canaries + fortified calls (soft — presence depends on code shape).

Deliberately disabled pending measurement (see the catalog comments): `-ftrivial-auto-var-init=zero`, `-fno-plt`. Build-on-target boxes may export `GCC_BUILD_MARCH=x86-64-v3` (or `native`) for a CPU baseline; default stays portable.
