# Adding a product to the kyr platform

Status: normative for every new product, 2026-09-28. Sources: REFACTORING_PLAN.md §0 (bar test 1), §2, §3, §3.5, §8; NAMING.md; kyr_shell docs/BUNDLE_CONTRACT.md (`kyr-shell/1`); kyr_fleet docs/edition_def.md. Tested by building kyr_estate with it, step by step. `$WS` is the directory holding the checkouts (`/home/rh/projects_clone` on the workstation), `<word>` the product's word (`estate`), `<WORD>` its upper case (`ESTATE`).

## The checklist (plan §8)

1. One repository from this template, tier 5, pinning the core's `-dev` package (never another module's), implementing the module descriptor and its web bundle.
2. One directory `kyr_server/editions/<word>/` with `main.c`, `modules.c`, `edition.def`, `site.schema`.
3. One product line in the platform repository.
4. One overlay per client machine in the inventory.
5. Nothing in kyr_host, the core, kyr_fleet, cicd.

Any line outside these five means the structure failed: stop and write the request in `$WS/_notes/<repo>.md` instead of working around it. Known failures today are at the end.

## What you must never touch

- kyr_host (tier 3): the process skeleton. A product adds no lane, limit or callback there.
- The core (DB_app → kyr_core, tier 4): identity, router, module contract, capability and reason registries, links, purge. A product adds no route, reason, capability or env there; it declares them in its own descriptor.
- kyr_fleet and kyr_fleet_inventory's code: the fleet knows bundles and machines, never products.
- cicd: workflows are ten-line callers of `c-quality`/`c-release@v2`, never copies.
- Another module's repository, including the one you reuse (drive): reuse is a seam in your repository and a binding in the edition (step 10), never a pin.

## Steps

1. **Name it** (NAMING.md). Module-based: repository `kyr_<word>`, C prefix `kyr_<word>_`, types `kyr_<word>_<thing>_t`, constants and macros `KYR_<WORD>_…`, include root `app/include/kyr/<word>/`, packages `libkyr-<word>`, `libkyr-<word>-dev`, `kyr-<word>-web`, linker map `utils/kyr_<word>.map`, envs `<word>.<name>`, capabilities `<word>.<object>.<verb>`, error tokens lowercase snake case, routes under `/api/app/<word>/`, bundle id, view prefix `<word>_` and edition name `<word>`, edition binary `kyr-server-<word>`. Process-based: the brand everywhere (`io_rms`, `iorms_`, `io-rms-server`). The word is `[a-z][a-z0-9]*`, not a vocabulary word of NAMING.md, not an existing repository word.

2. **Choose the shape.** Module-based unless one of these holds, then process-based: the server code is not C against the core's contract (another language, an existing program with its own kernel or CLI); it needs its own process model (long computations, its own threads or event loop, blocking I/O); or it must crash and restart without taking identity down. Product separation is total in both shapes; the shape only decides how a request arrives: through the core's router (module) or through nginx `auth_request` against `GET /api/app/authz` with `X-Auth-*` headers (process). Steps 3 to 19 are the module path; step 20 lists the process-based differences.

3. **Create the repository from the template shipped in the pinned kyr-build deb** (the source tree `kyr_build/share/template/` lacks `.clang-format`, which the deb adds). The `init` commit on master is the pristine template, so `git diff master` on `restructuring` is exactly the product:
   ```
   ver=2.0.1; deb=~/.cache/rh-deps/debs/kyr-build_${ver}_all.deb
   sha256sum "$deb"                          # equals the hash in $WS/_notes/kyr_build.md or the release's SHA256SUMS
   tmp=$(mktemp -d); dpkg-deb -x "$deb" "$tmp"
   mkdir "$WS/kyr_<word>" && cd "$WS/kyr_<word>"
   cp -a "$tmp/usr/local/share/kyr-build/template/." . && rm -rf "$tmp" && rm -f NEW_PRODUCT.md
   git init -b master && git add -A && git commit -m init && git checkout -b restructuring
   ```

4. **Rename the template word**, files then contents, and give the linker map the soname major (`0` while VERSION is `0.x`):
   ```
   git mv app/include/kyr/word app/include/kyr/<word>
   git mv app/include/kyr/<word>/word.h app/include/kyr/<word>/<word>.h
   git mv app/src/word.c app/src/<word>.c
   git mv tests/UTs/word_tests.c tests/UTs/<word>_tests.c
   git mv utils/kyr_word.map utils/kyr_<word>.map
   git mv utils/kyr_word_project.sh utils/kyr_<word>_project.sh
   git mv docs/diagrams/word_components.puml docs/diagrams/<word>_components.puml
   grep -rlI 'word' --exclude-dir=.git . | xargs sed -i -e 's/KYR_WORD_WORD_H/KYR_<WORD>_<WORD>_H/g' \
       -e 's/kyr_word/kyr_<word>/g; s/KYR_WORD/KYR_<WORD>/g; s/kyr-word/kyr-<word>/g; s#kyr/word#kyr/<word>#g; s/kyr word/kyr <word>/g' \
       -e 's/\bword\([._]\)/<word>\1/g'
   sed -i 's/KYR_<WORD>_1/KYR_<WORD>_0/' utils/kyr_<word>.map
   git grep -n -i 'word'                     # only the README's first line (prose) may remain; rewrite it
   ```
   LICENSE and `debian/copyright`: products are proprietary; copy `$WS/kyr_host/LICENSE` and fill `debian/copyright` (Upstream-Name `kyr_<word>`, the owner, `License: Proprietary`). VERSION stays `0.1.0` until the first release.

5. **Pin the toolchain** in `deps.txt`, exact version and the deb's sha256, never a placeholder:
   ```
   own     kyr-build                 2.0.1      RomanHorshkov/Utils    7068638f52c7d58968c419734a5cbf6ca2dfc9761459c3fac72cbb53649c1343
   ```
   Then `./utils/deps.sh sysroot && grep -w kyr_<word> build/sysroot/share/kyr-build/tiers.txt`. It must print `5 kyr_<word>`. kyr-build 2.0.1 does not list any product repository, so `deps.sh check --tiers` dies with "not in the tier map": request the line from kyr_build (known failure 1) and, until the pinned kyr-build carries it, add this guard to `utils/run_pipeline.sh` right after its `eval "$(./utils/deps.sh sysroot | grep '^export')"` line (it disappears by itself once the shipped map lists the repository):
   ```
   if ! grep -qw kyr_<word> "${KYR_BUILD_DIR}/tiers.txt"; then
       { cat "${KYR_BUILD_DIR}/tiers.txt"; printf '5 kyr_<word>\n'; } > build/tiers.txt
       export KYR_TIERS_FILE="${ROOT_DIR}/build/tiers.txt"
   fi
   ```
   Run `./utils/run_pipeline.sh` now: the renamed template is green, and every later step keeps it green. Commit.

6. **Pin what the core pins**, at the core's exact versions, because the module and the core link into one edition binary: copy the lines from the core's `deps.txt` (`$WS/DB_app/deps.txt` today) with their sha256 (`sha256sum ~/.cache/rh-deps/debs/<pkg>_<ver>_*.deb` when a line is new). You need `libdb-lmdb-dev` for the env descriptor type; the `-dev` debs of `libfsutil`, `libuuid7`, `libemlog` when a test links DB_lmdb's static archive (the core pins the runtime debs, which carry no `.a`); and the core's own `-dev` once a release ships the module contract (step 9). Keep comments off `apt` lines: `deps.sh` reads the next word as the minimum version.
   ```
   apt     liblmdb-dev
   own     libdb-lmdb-dev            1.11.0     RomanHorshkov/DB_lmdb   ca81b9372ddc016183755e7d2cc5ff6beb8131c43cb9c66fce1145e0ad9dff77
   own     libfsutil-dev             1.1.3      RomanHorshkov/fs_util   7206edf9b8d0bece04c366fb709d8be1b13a15d99421afb6cb3930a6fd56b4aa
   own     libuuid7-dev              1.1.2      RomanHorshkov/uuid7     446ae1aa6db1aa5952250960cb98ed92109e859ac255ad0c1ee9b3288edbc4f3
   own     libemlog-dev              1.4.0      RomanHorshkov/EMlog     9ea28d47d82efb18b58b42f5ffb35d0eddd7a632a4da2b6ed3bbcead1c450544
   ```

7. **Replace the template's code** with your own: list the sources in `KYR_LIB_SOURCES` and the tests in `KYR_TEST_SOURCES` of `utils/kyr_<word>_project.sh`, and the archives a test links in `KYR_TEST_LDLIBS` (for DB_lmdb: `-l:libdb_lmdb.a -l:libfsutil.a -l:libuuid7.a -l:libemlog.a -llmdb -lm -pthread`). After removing or renaming a test source, `rm -rf build/{debug,audit,sanitize,release,native,extreme}`: kyr-build 2.0.1's `run_tests.sh` counts stale executables and fails (known failure 3). The library references DB_lmdb's types only, so its shared object needs no DB_lmdb link. `./utils/format.sh` before every commit; the pipeline's format stage checks it.

8. **Declare the environments and the records** (`app/include/kyr/<word>/envs.h`, `records.h`). An env is the core's env definition (`db_app_env_def_t` in `$WS/DB_app/app/include/db_app/database/schema.h`: name, renamed_from, DB_lmdb DBI descriptors, count, migration class, schema version; the core composes it into a `db_lmdb_env_desc_t` and picks the map size): names `<word>.<name>` (box-wide; never `core.*` or another product's namespace); one env per independent writer family, records that change in one transaction in one env; record DBIs bounded-variable (`max_val_len` ≥ the codec's largest encoding, with headroom, never `fixed_val_len`); index DBIs fixed keys and values, `DUP_SORT|DUP_FIXED` where one key maps to many ids; `schema_version = 1`, `renamed_from = NULL`; migration class (plan §6.2) `none` in the first release, `append` when a later release adds DBIs or an env, `rewrite` or `irreversible` only with a rehearsal. Records start with `ver`, a u32 little-endian (the core's `migrate` reads the first four bytes of every row); one field table per record and version, one generic encoder and decoder, integers little-endian, text a u16 length plus UTF-8 without NUL and a declared maximum; every codec reads every version it ever wrote. Gates, cmocka: round trip of every record, golden bytes, every truncation, trailing bytes, unknown `ver`, out-of-range enum, over-long or malformed text, a capture of every layout (re-captured only for a new `ver`); every record DBI's bound holds its record; `db_lmdb_open` accepts the envs (turned into DB_lmdb descriptors the way the core does) in a `mkdtemp` root and reopens them under a strict manifest.

9. **Implement the module descriptor**: one `const` object `kyr_<word>_module` in `app/src/module.c`. The type is the core's `db_app_module_t` in `$WS/DB_app/app/include/db_app/module.h` (`<kyr/core/module.h>` and `kyr_core_module_t` after the rename). Its field list differs slightly from plan §3.2 (a records table, CLI commands, reasons by pointer, `migrate` and `check` on a context, integer link kinds) and may still move while the core lands it: follow the header, not the plan.
   ```c
   const <module type> kyr_<word>_module = {
       .size = sizeof(<module type>), .abi_major = 1, .abi_minor = 0, .id = "<word>",
       .routes = ROUTES, .n_routes = KYR_<WORD>_ROUTE_COUNT,    .envs = kyr_<word>_envs, .n_envs = KYR_<WORD>_ENV_COUNT,
       .caps = CAPS, .n_caps = KYR_<WORD>_CAP_COUNT,             .reasons = REASONS, .n_reasons = KYR_<WORD>_REASON_COUNT,
       .records = RECORDS, .n_records = KYR_<WORD>_REC_COUNT,    /* name, env, dbi, flags, newest, sizes[ver], struct_size, decode, encode */
       .boot = boot, .shutdown = stop, .migrate = migrate, .check = check,
       .purge = NULL, .link_kinds = NULL, .n_link_kinds = 0, .commands = NULL, .n_commands = 0, .sinks = NULL, .sources = NULL,
   };
   ```
   Until a pinned core release ships that header, mirror it once in `app/include/kyr/<word>/contract.h` with your own prefix (`kyr_<word>_route_t`, `_env_def_t`, `_cap_t`, `_reason_t`, `_record_desc_t`, `_module_env_t`, `_migrate_ctx_t`, `_purge_hook_t`, `_link_kind_t`, `_cli_command_t`, `_module_t`, the core's status values; request, response, actor and check context as incomplete types), so the switch is one file of aliases. Routes, capabilities and reasons are X-macro `.def` tables next to the headers (`routes.def`: method, path under `/api/app/`, `dpop_htu` = the path, policy, platform-role floor, flags, handler); an empty routes table stays valid ISO C with one spare zero element and `n_routes = 0`. The template's `build_deb.sh` installs only `*.h`: change its `find … -name '*.h'` to `\( -name '*.h' -o -name '*.def' \)` (known failure 4), and keep an IT that compiles a composition root from the extracted `-dev` deb alone. `boot` refuses anything unbound; `migrate` has no step of its own until a layout changes (the core already rewrote every row); `check` walks the envs (OK until there is data). Gate: a unit test on the descriptor (size, ABI, id, counts, labels, reasons as canned `{"error":"<token>"}`, every record's codec through the core's signatures, boot).

10. **Reuse another module as a library** (the data room on drive) without pinning it: two tier-5 repositories may not pin each other (`deps.sh check --tiers`), no repository below kyr_server sees more than one module (plan §3), and the platform refuses a vertical that requires another vertical (`dbctl product validate`). Declare the seam as an ops struct in your own header (`kyr_<word>_room_ops_t`: create a folder for an owner with a quota, share to a uid at a level, seal, usage, purge) with `kyr_<word>_rooms_bind(const ops*)`, which the edition calls before `kyr_host_main`; `boot` refuses while unbound. Your env holds the policy, the other module the bytes and the enforcement; order the two writes so a crash leaves access stricter (grant: your env first; revoke: the seam first), and let `check` report drift.

11. **Declare the rights** (plan §3.5) in `docs/RIGHTS.md`, `caps.def` and `rights.h`: accounts, sessions and the platform role are the core's; every product role and scope (membership, grant, side, moderator) lives in your envs keyed by the platform uid. Each capability has a platform-role floor (the core's values VIEWER 1, PUBLISHER 2, ADMIN 4, OWNER 128; a floor, never the capability) and the product condition that must also hold. The decision is one pure function over (capability, facts the caller read in its transaction); a unit test walks the table. Separation-of-duties rules are enforced in your own transactions.

12. **Write the web bundle** against `kyr-shell/1` in `web/<word>/`: `bundle.js` with `contract: "kyr-shell/1",` on its own line, `id: "<word>"`, `html: "<word>/<word>.html"`, `nav` entries whose views (`<section id="view-<view>" class="view" hidden>`) exist in the fragment, are prefixed `<word>_` and are not shell views (`home nerd users system me admin`); imports only `../js/api.js`, `../js/proof.js`, `../js/format.js`, `../js/i18n.js`, `../js/links_api.js` and the bundle's own files; never `fetch` itself; no inline script, `on*=` or `style=`; files `.js .html .css .woff2` only; every call inside `ctx.authed()` with a fresh proof, `htu` = the path after `/api/app/`. Nav `capability` gates only by the platform role through `/me`, so when every capability has the VIEWER floor leave it out and let each view gate itself on the product's own `GET <word>/me`. Signed-out pages (a public site) cannot be bundle views in kyr-shell/1: ship them as static pages under `web/<word>/site/`. No `data-i18n` keys until the shell has per-bundle dictionaries (its parity gate reads only its own). A product cannot pin kyr-shell (tier 6), so check your side of the contract with a script of your own and an IT that also proves each refusal (kyr_estate: `tests/support/check_bundle.py`, `tests/ITs/web_bundle.sh`; known failure 2). Package it in `utils/build_deb.sh`, before `deb_sha256sums`:
   ```
   stage="$(deb_stage kyr-<word>-web share/kyr/web)"
   cp -a "${ROOT_DIR}/web/<word>" "${stage}/usr/local/share/kyr/web/<word>"
   find "${stage}/usr/local/share/kyr/web" -type f -exec chmod 0644 {} +
   deb_control "${stage}" kyr-<word>-web web all "kyr <word> web bundle (kyr-shell/1)"
   deb_copyright "${stage}" kyr-<word>-web
   deb_build "${stage}" kyr-<word>-web all
   ```

13. **Write the docs**: `docs/DOMAIN.md` (entities, relations, state machines, envs, the layout capture), `docs/RIGHTS.md`, `docs/WIRE.md` (every route under `/api/app/<word>/`, bodies, answers, errors, paging as io_rms: `limit` ∈ {10, 40, 80, 120}, opaque `after`, `{"items","has_more","next_after"}`, `400 cursor_invalid`), `docs/diagrams/*.puml` with one claim each (components, domain, rights, a request sequence, one state diagram per state machine, the seam), and a terse README, never hard-wrapped, with one line naming the diagrams.

14. **Run the gates**, from the sysroot, no sudo, nothing from `/usr/local`:
   ```
   ./utils/deps.sh sysroot && eval "$(./utils/deps.sh sysroot | grep '^export')"
   ./utils/run_pipeline.sh                   # deps-tiers, template, format, 6 profiles, UTs x audit/sanitize/release, ITs, package
   "$KYR_BUILD_DIR/template_check.sh" "$PWD"
   ```
   Done only at `pipeline GREEN`. One commit per step, message = what the change is.

15. **Hand off** after the last commit (the debs' bytes depend on the commit time): `./utils/build_deb.sh && cp build/debs/*.deb ~/.cache/rh-deps/debs/ && cat build/debs/SHA256SUMS`, and give consumers the pin lines. Bump VERSION (SemVer) on any API or ABI change; a new record layout is a new `ver`, never an edit of an old one.

16. **The edition directory** (kyr_server, today DB_server; its owner makes the change, you send the files):
   ```
   editions/<word>/modules.c      the module array { &kyr_drive_module, &kyr_<word>_module } and the seam adapter over drive's API
   editions/<word>/main.c         kyr_<word>_rooms_bind(&ROOMS_ON_DRIVE); return kyr_host_main(argc, argv, kyr_core_app(MODULES, n));
   editions/<word>/edition.def    FORMAT=1, EDITION=<word>, WEB_BUNDLES="shell <word>", one core process kyr-server-<word> (AUTH_REQUEST=no, MOUNT=/api/app),
                                  PROCESS_1_ENVS = core.user core.auth, the reused modules' envs, every <word>.* env; one ENV_n block each with SCHEMA and MIGRATION
   editions/<word>/site.schema    the config keys (the platform generates it: ops/gen_site_schema.sh)
   editions/<word>/routes.stream  the process's streamed routes (the reused module's upload lanes)
   editions/<word>/build          empty marker, once both module debs are pinned: utils/build_bin.sh builds the edition
   ```
   Check the edition.def before sending it with both parsers: `bash -c 'source $WS/DB_server/utils/lib/edition.sh && edition_load edition.def'` and `bash -c 'cd $WS/kyr_fleet && source lib/parse.sh && source lib/manifest.sh && edition_load <abs path>'`. In the edition repository: pin `libkyr-<word>-dev` and `kyr-<word>-web` with sha256, then `./utils/gen_edition.sh <word> && ./utils/check_editions.sh && ./utils/run_pipeline.sh`.

17. **The product line in the platform repository** (DB → kyr; its owner makes the change): `products/<word>/edition.def` and `site.schema` byte-identical to the edition's, `products/<word>/product.manifest` (`PRODUCT_STATE=planned` until the first bundle ships, `MODULES` with the kernel modules, the reused module and `<word>`, `WEB_BUNDLES="shell <word>"`, `PACKAGES="kyr-server-<word> kyr-<word>-web"`), `modules/<word>/module.manifest` (`TIER=vertical`, `REQUIRES` kernel modules only, `CAPABILITY` = every label of `caps.def`, `ENVS`, `WEB_BUNDLE`), the pins in `deps.txt`; then `./dbctl product validate <word> && ./ops/check_all.sh`. Try it first on a scratch copy (`git -C $WS/DB ls-files -z | tar --null -T - -cf - | tar -C <scratch> -xf -`).

18. **Build a bundle** (workstation, from the cache, no network). The web root, with the real shell:
   ```
   dpkg-deb -x ~/.cache/rh-deps/debs/kyr-shell_<ver>_all.deb sh && dpkg-deb -x ~/.cache/rh-deps/debs/kyr-<word>-web_<ver>_all.deb wb
   SOURCE_DATE_EPOCH=<platform tag commit time> $WS/kyr_shell/utils/compose_web.sh --shell sh/usr/local/share/kyr/shell \
       --bundle wb/usr/local/share/kyr/web/<word> --out web --product <word>
   python3 $WS/kyr_shell/utils/check_composed.py web <word>
   ```
   Then the bundle, once the edition binary's deb is pinned in the platform: `SOURCE_DATE_EPOCH=… $WS/kyr_fleet/bin/kyr-bundle build --edition <word> --from $WS/DB/deps.txt --cache ~/.cache/rh-deps/debs --editions-dir $WS/DB_server/editions --calver YYYY.MM.0 --seq 1 --web-root web --out bundles`, twice, hashes compared, then `kyr-bundle verify` and `fleet bundle sign … --namespace kyr-candidate`.

19. **The VM lane** (the owner; needs the VM): `fleet machine add vm rh@<vm> --edition <word> --environment test --channel candidate` → `fleet machine enroll vm` → `fleet provision vm` → `fleet site-env vm --bundle <b>` → `fleet plan vm --bundle <b>` → `fleet apply vm --plan <id>` → `fleet status vm`; then the platform's black-box suite, `tests/upgrade/run_matrix.sh` and `tests/restore/run_drill.sh`. For a client: one overlay per machine in kyr_fleet_inventory (checklist line 4).

20. **Process-based differences**: the repository implements the host descriptor (`kyr_host_main(argc, argv, &APP)`, pin `libkyr-host-dev`), mounts beside the core (`/api/<word>`), takes identity only from `X-Auth-User`, `X-Auth-Role`, `X-Auth-State`, `X-Auth-Session` (a request without them is `500 server_error`, never `401`), owns exactly one env `<brand>.main`, and its `edition.def` process has `AUTH_REQUEST=yes`. The edition's `modules.c` is `{ }` when no module product shares the box.

## Known failures (the structure against bar test 1), each a request in `$WS/_notes/kyr_estate.md`

1. The tier map is a list inside kyr-build: a new product needs a line there and a kyr-build release (the step 5 guard is the interim). Fix proposed: a `kyr_*` fallback at tier 5 for repositories the map does not name.
2. The product side of `kyr-shell/1` has no shared checker below tier 6, so each product carries its own. Fix proposed: ship `check_bundle.py` in kyr-build.
3. `run_tests.sh` counts stale test executables (step 7). Fix proposed: `kyr_build_tests` empties `build/<profile>/tests` first.
4. The template's `build_deb.sh` drops `.def` tables from the `-dev` deb (step 9). Fix proposed: install every file under `app/include`.
5. The core's record contract (DB_app working tree) caps every record at 1024 encoded bytes and 1024 bytes decoded (`DB_APP_RECORD_ENC_MAX`, `DB_APP_RECORD_STRUCT_MAX`, refused at compose) and treats a row as current only at the newest layout's exact size, so a product with prose (estate's listing text, answers, reviews) is refused, and variable-length rows would be rewritten by every `migrate`. Fix proposed: size the scratch from the composed records and accept `ver == newest` with any size up to `sizes[newest]` for records flagged variable.
6. The core's env definition carries no map size, so a module cannot say that one env grows faster than another. Fix proposed: an optional `map_size_max` in `db_app_env_def_t`, overridable from `site.env`.
