# kyr_word

One sentence: what this repository is (its vocabulary word from NAMING.md) and what it produces (`libkyr-word`, `libkyr-word-dev`).

Build: `./utils/deps.sh sysroot && eval "$(./utils/deps.sh env)" && ./utils/run_pipeline.sh`. Pins live in `deps.txt`; tooling is the pinned `kyr-build`, never a copy. Profiles: `./utils/gcc_build_profiles.sh explain`. Project flags: `utils/kyr_word_project.sh`.

Release: master green, signed tag `v<VERSION>`, `release.yml` publishes the debs, `SHA256SUMS` and one `.buildinfo` per deb.

Diagrams: `docs/diagrams/word_components.puml` (public surface), `docs/diagrams/word_sequence.puml` (main flow).
