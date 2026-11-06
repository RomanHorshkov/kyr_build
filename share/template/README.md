# kyr_word

One sentence: what this repository is (its vocabulary word from NAMING.md) and what it produces (`libkyr-word`, `libkyr-word-dev`).

Build: `./utils/deps.sh sysroot && eval "$(./utils/deps.sh env)" && ./utils/run_pipeline.sh`. Pins live in `deps.txt`, whose first line declares the repository's tier (`# tier: 5 product`; `./utils/deps.sh check --tiers` enforces it against every pin's `X-Kyr-Tier`); tooling is the pinned `kyr-build`, never a copy. Profiles: `./utils/gcc_build_profiles.sh explain`. Project flags: `utils/kyr_word_project.sh`.

Template drift (`template_check.sh`, a CI gate): every wrapper in `utils/` is byte-identical to the pinned kyr-build's, and `utils/` holds nothing else but the project file, linker maps and the gates `KYR_REPO_GATES` lists; `VERSION`, `deps.txt`, `LICENSE`, `README.md` and `utils/deps.sh` exist, and with C in the tree also kyr-build's `.clang-format`, `quality.yml`, `utils/gcc_build_profiles.sh` and `utils/check_hardening.sh` (`utils/check_abi.sh` with `abi/layout.txt`, `utils/vendor.sh` with `app/extern`). A repository with no C (a web shell, a manifest) needs neither the catalog, the gate, `.clang-format` nor `quality.yml`.

ABI (optional, a library consumers link): `./utils/check_abi.sh --update` writes `abi/layout.txt` from the public headers (every struct's layout, enumerator values, #define constants, callbacks, function signatures); from then on the pipeline refuses a changed or removed line without a raised major, a new public name without a raised minor (against the last `v<x.y.z>` tag), and a library that does not export exactly the declared functions as `<name>@@<NODE>_<major>`. What is public: `KYR_ABI_*` in the project file (defaults from `KYR_LIB`).

Release: master green, signed tag `v<VERSION>`, `release.yml` publishes the debs, `SHA256SUMS` and one `.buildinfo` per deb.

Diagrams: `docs/diagrams/word_components.puml` (public surface).
