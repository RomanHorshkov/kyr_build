# kyr_word

One sentence: what this repository is (its vocabulary word from NAMING.md) and what it produces (`libkyr-word`, `libkyr-word-dev`).

Build: `./utils/deps.sh sysroot && eval "$(./utils/deps.sh env)" && ./utils/run_pipeline.sh`. Pins live in `deps.txt`, whose first line declares the repository's tier (`# tier: 5 product`; `./utils/deps.sh check --tiers` enforces it against every pin's `X-Kyr-Tier`); tooling is the pinned `kyr-build`, never a copy. Profiles: `./utils/gcc_build_profiles.sh explain`. Project flags: `utils/kyr_word_project.sh`.

Template drift (`template_check.sh`, a CI gate): the four wrappers and `.clang-format` are byte-identical to the template; `VERSION`, `deps.txt`, `LICENSE`, `README.md` and `quality.yml` exist. A repository with no C under `app/` (a web shell, a manifest) keeps only `utils/deps.sh` (and `utils/vendor.sh` when it vendors); the catalog, the gate, `.clang-format` and `quality.yml` are not required there.

Release: master green, signed tag `v<VERSION>`, `release.yml` publishes the debs, `SHA256SUMS` and one `.buildinfo` per deb.

Diagrams: `docs/diagrams/word_components.puml` (public surface), `docs/diagrams/word_sequence.puml` (main flow).
