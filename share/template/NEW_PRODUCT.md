# Adding a product to the kyr platform

Status: normative for every new product, 2026-09-29 (revised after kyr_estate 1.0.0 moved onto the real core: DB_app 2.0.0, kyr_drive 2.0.0; revised 2026-10-03 for DB_app 2.1.0 and kyr-shell 1.1.0: the boot env, the listing tag registry, the full-path DPoP htu of decision D33 with contract `kyr-shell/2`, the core's JSON body reader). Sources: REFACTORING_PLAN.md §0 (bar test 1), §2, §3, §3.5, §8, §11 (D33); NAMING.md; kyr_shell docs/BUNDLE_CONTRACT.md (`kyr-shell/2`); kyr_fleet docs/edition_def.md. Tested by building kyr_estate with it, step by step. `$WS` is the directory holding the checkouts (`/home/rh/projects_clone` on the workstation), `<word>` the product's word (`estate`), `<WORD>` its upper case (`ESTATE`).

## The checklist (plan §8)

1. One repository from this template, tier 5, pinning the core's package (`libdb-app`: headers, archive and shared object) and the core's own pins and nothing of another product, implementing the module descriptor and its web bundle. A capability it wants from another product (estate's data room from drive) is a hook the product owns, bound to the other product's functions in the edition's `modules.c`.
2. One directory `kyr_server/editions/<word>/` with `main.c`, `modules.c`, `edition.def`, `site.schema`.
3. One product line in the platform repository.
4. One overlay per client machine in the inventory.
5. Nothing in kyr_host, the core, kyr_fleet, cicd (nor kyr_build: a product declares its own tier).

Any line outside these five means the structure failed: stop and write the request in `$WS/_notes/<repo>.md` instead of working around it. Known failures today are at the end.

## What you must never touch

- kyr_host (tier 3): the process skeleton. A product adds no lane, limit or callback there.
- The core (DB_app → kyr_core, tier 4): identity, router, module contract, capability and reason registries, links, purge. A product adds no route, reason, capability or env there; it declares them in its own descriptor.
- kyr_fleet and kyr_fleet_inventory's code: the fleet knows bundles and machines, never products.
- cicd: workflows are ten-line callers of `c-quality`/`c-release@v2`, never copies.
- kyr_build: the product declares its tier in its own `deps.txt`; kyr-build's tier map lists only the platform's fixed repositories and never a product.
- Another module's repository, including the one you reuse (drive): reuse is a hook in your repository and a binding in the edition (step 10), never a pin.

## Steps

1. **Name it** (NAMING.md). Module-based: repository `kyr_<word>`, C prefix `kyr_<word>_`, types `kyr_<word>_<thing>_t`, constants and macros `KYR_<WORD>_…`, include root `app/include/kyr/<word>/`, packages `libkyr-<word>`, `libkyr-<word>-dev`, `kyr-<word>-web`, linker map `utils/kyr_<word>.map`, envs `<word>.<name>`, capabilities `<word>.<object>.<verb>`, error tokens lowercase snake case, routes under `/api/app/<word>/`, bundle id, view prefix `<word>_` and edition name `<word>`, edition binary `kyr-server-<word>`. Process-based: the brand everywhere (`io_rms`, `iorms_`, `io-rms-server`). The word is `[a-z][a-z0-9]*`, not a vocabulary word of NAMING.md, not an existing repository word.

2. **Choose the shape.** Module-based unless one of these holds, then process-based: the server code is not C against the core's contract (another language, an existing program with its own kernel or CLI); it needs its own process model (long computations, its own threads or event loop, blocking I/O); or it must crash and restart without taking identity down. Product separation is total in both shapes; the shape only decides how a request arrives: through the core's router (module) or through nginx `auth_request` against `GET /api/app/authz` with `X-Auth-*` headers (process). Steps 3 to 20 are the module path; step 21 lists the process-based differences.

3. **Create the repository from the template shipped in the pinned kyr-build deb** (the source tree `kyr_build/share/template/` lacks `.clang-format`, which the deb adds). The `init` commit on master is the pristine template, so `git diff master` on `restructuring` is exactly the product:
   ```
   ver=2.0.7; deb=~/.cache/rh-deps/debs/kyr-build_${ver}_all.deb
   sha256sum "$deb"                          # equals the hash in $WS/_notes/kyr_build.md or the release's SHA256SUMS
   tmp=$(mktemp -d); dpkg-deb -x "$deb" "$tmp"
   mkdir "$WS/kyr_<word>" && cd "$WS/kyr_<word>"
   cp -a "$tmp/usr/local/share/kyr-build/template/." . && rm -rf "$tmp" && rm -f NEW_PRODUCT.md
   git init -b master && git add -A && git commit -m init && git checkout -b restructuring
   ```

4. **Rename the template word**, files then contents (the linker map's node becomes `KYR_<WORD>_0`, the soname major while VERSION is `0.x`):
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
   git grep -n -i 'word'                     # only the README's first line (prose) may remain; rewrite it
   ```
   LICENSE and `debian/copyright`: products are proprietary; copy `$WS/kyr_host/LICENSE` and fill `debian/copyright` (Upstream-Name `kyr_<word>`, the owner, `License: Proprietary`). VERSION stays `0.1.0` until the first release; the ABI gate has no 0.x rule (step 15), so the first public-contract change after the layout is frozen is the product's `1.0.0`.

5. **Declare the tier and pin the toolchain.** The first line of `deps.txt` is the repository's tier (plan §2.1): the template's `# tier: 5 product`, which a product keeps. `lib/deb.sh` writes it into every deb as `X-Kyr-Tier`, and `deps.sh check --tiers` refuses any pin that is not of a strictly lower tier, reading the pin's tier from the pinned deb; kyr-build's tier map lists only the platform's fixed repositories, never a product, so nothing in kyr_build changes for a new product. Pin kyr-build by exact version and the sha256 of the deb (`$ver` and `$deb` from step 3; the hash equals the one in `$WS/_notes/kyr_build.md` or the release's SHA256SUMS):
   ```
   sed -i -E "s|^own +kyr-build .*|own     kyr-build                 ${ver}      RomanHorshkov/Utils    $(sha256sum "$deb" | cut -d' ' -f1)|" deps.txt
   head -1 deps.txt                          # # tier: 5 product
   ./utils/deps.sh sysroot > /dev/null && ./utils/deps.sh check --tiers    # "kyr_<word> declares tier 5 (product)", "a product"
   ```
   Run `./utils/run_pipeline.sh` now: the renamed template is green, and every later step keeps it green. Commit.

6. **Pin the core and what the core pins**, at the core's exact versions, because the module and the core link into one edition binary: `libdb-app` (one deb: `db_app/*.h`, `libdb_app.a`, `libdb_app.so.2`; its FINAL line in `$WS/_notes/DB_app.md`) and every `apt` and `own` line of the core's `deps.txt` (`$WS/DB_app/deps.txt`) with its sha256 (`sha256sum ~/.cache/rh-deps/debs/<pkg>_<ver>_*.deb` when a line is new). With the tests linking the shared core (step 7), no foundation `-dev` archive is needed beyond the ones the core pins. Pin 2.1.0 or later: it is the first core with the boot-env guarantee, the listing tag registry, the full-path htu and the JSON body reader the known pitfalls below rely on, and its own pins are 2.0.0's. Today, for DB_app 2.1.0:
   ```
   apt     libsodium-dev
   own     libdb-app                 2.1.0      RomanHorshkov/DB_app    541d5896395c92a447b89aee3cbbf3f7abccae61be08feeade35793f1ce4f1d0
   own     rh-util-memory-macros     1.0.1      RomanHorshkov/Utils     4923c7823f4096da51a9b7bfc6ce1078d3756afbf6e05fd1de5ea80e01ebcb0d
   own     rh-util-string-view       1.0.1      RomanHorshkov/Utils     0e85f889aecdb6be1264583f526f9f3a6896ea9170f48aa45dbd1286f939179a
   own     libemlog                  1.4.0      RomanHorshkov/EMlog     84d5fa193086640eb8b79c22879daa712755203fa1da57c85a1e378bb62607cc
   own     libemlog-dev              1.4.0      RomanHorshkov/EMlog     9ea28d47d82efb18b58b42f5ffb35d0eddd7a632a4da2b6ed3bbcead1c450544
   own     libuuid7                  1.1.2      RomanHorshkov/uuid7     336d5d14f15a7393847320a5d2105ac8b4710f90c13bd19a5a839aaee16cff3c
   own     libuuid7-dev              1.1.2      RomanHorshkov/uuid7     446ae1aa6db1aa5952250960cb98ed92109e859ac255ad0c1ee9b3288edbc4f3
   own     libmpscring               1.0.6      RomanHorshkov/MPSCring  8089755f53f2d98f0132f0d923a92d718b9659d3535f482e8fe081200ce1dbb5
   own     libmpscring-dev           1.0.6      RomanHorshkov/MPSCring  e689d77361507987a04b8a4ad845cece2d1c7e42116683b04d7deac923beb2de
   own     libfsutil                 1.1.3      RomanHorshkov/fs_util   79bb7b20d89ec223bd734be52915d39d26ee599b40029d392657efaf1ff6712b
   own     db-http                   2.0.0      RomanHorshkov/DB_http   f2d26cc17f89038ed69117757f7b4eb6e7276e7d258ea543f8ee8f79ac0abfb3
   own     libdb-jose-dev            2.0.0      RomanHorshkov/DB_jose   13f0138822c6e4e813bc850a75e88c64c0cf3989873f85f48ecb5fa2403c283e
   own     libdb-lmdb-dev            2.0.0      RomanHorshkov/DB_lmdb   4e05b880b46705a6e718b02b172e52b7a0cf3143e388972bf8cb4a7e7e7489fb
   ```
   `deps.sh check --tiers` reads libdb-app as `X-Kyr-Tier: 4 core`, below your 5. Your `-dev` deb depends on `libdb-app (>= <pinned>)`: its headers include the core's (`utils/build_deb.sh`, kyr_estate's).

7. **Replace the template's code** with your own: list the sources in `KYR_LIB_SOURCES` and the tests in `KYR_TEST_SOURCES` of `utils/kyr_<word>_project.sh`, and point the build at the core in the sysroot:
   ```
   DEPS_INC="${KYR_<WORD>_DEPS_INCLUDE_DIR:-${ROOT_DIR}/build/sysroot/include}"
   DEPS_LIB="${KYR_<WORD>_DEPS_LIB_DIR:-${ROOT_DIR}/build/sysroot/lib}"
   KYR_LIB_CPPFLAGS=(-I"${ROOT_DIR}/app/include" -isystem "${DEPS_INC}" -isystem "${DEPS_INC}/db_jose" -isystem "${DEPS_INC}/db_jose/common")
   KYR_LIB_LDLIBS=(-L"${DEPS_LIB}" -ldb_app -ldb_lmdb -luuid7)
   KYR_TEST_LDLIBS=(-ldb_lmdb -pthread)
   ```
   The shared object links `libdb_app.so.2` (and DB_lmdb and uuid7 when it calls them), and the template's `build_tests.sh` links the tests against the same shared core, so the suite reaches nothing the core does not export (the edition links the archives; the IT of step 9 does both). The `db_jose` paths are needed by whatever includes the core's `jose_adapter.h` (the test harness signs DPoP proofs with it). `./utils/format.sh` before every commit; the pipeline's format stage checks it.

8. **Declare the environments and the records** (`app/include/kyr/<word>/envs.h`, `records.h`). An env is the core's env definition (`db_app_env_def_t` in `<db_app/database/schema.h>`: name, renamed_from, DB_lmdb DBI descriptors, count, migration class, schema version), and its map maximum is yours: an array `kyr_<word>_env_map_max[]` (bytes of address space per env, 0 = the platform's `DB_APP_DB_MAP_MAX_MIB`; `DB_APP_DB_MAP_MAX_MIB_<WORD>_<NAME>` overrides one on a box) that the descriptor hands the core (`env_map_max`, ABI 1.1); the core composes both into `db_lmdb_env_desc_t`: names `<word>.<name>` (box-wide; never `core.*` or another product's namespace); one env per independent writer family, records that change in one transaction in one env; record DBIs bounded-variable (`max_val_len` ≥ the codec's largest encoding, with headroom, never `fixed_val_len`); index DBIs fixed keys and values, `DUP_SORT|DUP_FIXED` where one key maps to many ids; `schema_version = 1`, `renamed_from = NULL`; migration class (plan §6.2) `none` in the first release, `append` when a later release adds DBIs or an env, `rewrite` or `irreversible` only with a rehearsal. Records start with `ver`, a u32 little-endian (the core's `migrate` reads the first four bytes of every row); every record type is `DB_APP_RECORD_VARIABLE` in the descriptor with `sizes[ver]` = the widest encoding of that layout (the core then takes a row at the newest layout as current whatever its length and rewrites only older layouts; without the flag every shorter row is rewritten at each `migrate`), plus `DB_APP_RECORD_UUID7_KEY` when the key is a uuid7 you mint; one field table per record and version, one generic encoder and decoder, integers little-endian, text a u16 length plus UTF-8 without NUL and a declared maximum; every codec reads every version it ever wrote. Gates, cmocka: round trip of every record, golden bytes, every truncation, trailing bytes, unknown `ver`, out-of-range enum, over-long or malformed text, a capture of every layout (re-captured only for a new `ver`); every record DBI's bound holds its record; `db_lmdb_open` accepts the envs (turned into DB_lmdb descriptors the way the core does, mapped at your maxima) in a `mkdtemp` root and reopens them under a strict manifest; and, once routes write rows (step 9), `db_app_migrate` over the closed database twice rewrites none of them (kyr_estate `tests/UTs/migrate_tests.c`).

9. **Implement the module descriptor and its routes**: one `const db_app_module_t kyr_<word>_module` in `app/src/module.c`, declared in your public `module.h`. The type is the core's own, from the pinned `libdb-app` (`<db_app/module.h>`; `<kyr/core/module.h>` and `kyr_core_module_t` after the rename), at descriptor ABI 1.1; never mirror it in your headers.
   ```c
   const db_app_module_t kyr_<word>_module = {
       .size = sizeof(db_app_module_t), .abi_major = DB_APP_MODULE_ABI_MAJOR, .abi_minor = DB_APP_MODULE_ABI_MINOR, .id = "<word>",
       .routes = ROUTES, .n_routes = sizeof ROUTES / sizeof ROUTES[0], .envs = kyr_<word>_envs, .n_envs = KYR_<WORD>_ENV_COUNT,
       .caps = CAPS, .n_caps = KYR_<WORD>_CAP_COUNT,             .reasons = REASONS, .n_reasons = KYR_<WORD>_REASON_COUNT,
       .records = RECORDS, .n_records = KYR_<WORD>_REC_COUNT,    /* name, env, dbi, DB_APP_RECORD_VARIABLE[|UUID7_KEY], newest, sizes, struct_size, decode, encode */
       .boot = boot, .shutdown = stop, .migrate = migrate, .check = check,
       .purge = NULL, .link_kinds = NULL, .n_link_kinds = 0, .commands = NULL, .n_commands = 0, .sinks = NULL, .sources = NULL,
       .env_map_max = kyr_<word>_env_map_max,                   /* ABI 1.1: read because `size` covers it */
   };
   ```
   Capabilities (`db_app_cap_def_t {label, floor}`) and reasons (`static DB_APP_REASON_DEFINE(...)`, an array of pointers, each with its HTTP status in your table) come from X-macro `.def` tables in your public headers, which the template's `build_deb.sh` ships in the `-dev` deb. The route table is private: `app/src/routes.def`, rows `X(NAME, method, path, htu, policy, floor, flags, handler)` expanded with `DB_APP_ROUTE_ENTRY`, every path `<word>/…` under `/api/app/`, the core's role floor VIEWER when your rights decide (step 11). A route with an id in its path is a prefix route: `DB_APP_ROUTE_FLAG_PREFIX` on `<word>/<noun>`, the handler parsing `<id>/<verb>` from the suffix; the row's htu column is informational, because the core binds every proof to the full request path (pitfall 3). Handlers have the core's signature, fill the response on every path, read their bodies with the core's `db_app/request/json.h` under limits taken from your record bounds (pitfall 6), read their envs in read-only transactions of `req->thread_id` on `db_app_database_engine()`, write through `db_app_txn_queue_submit(env, job, ctx)` (one job = one atomic change of one env, re-reading inside the job the facts it decides on), page through the core's `db_app_listing_run` under a tag of the block `boot` reserved (its MAC-bound cursor; map its `BAD_REQ` to your `400 cursor_invalid`) and build answers in the core's response arena with every string escaped. Private functions must not carry the `kyr_<word>_` prefix: the linker map exports `kyr_<word>_*`, and `abi-exports` requires exactly the declared functions. `boot` copies its env (pitfall 1), reserves its listing tags (pitfall 2) and refuses anything unbound (the hook of step 10); `migrate` has no step of its own until a layout changes (the core already rewrote every older row); `check` walks the envs.

   Gates. A unit test that the core composes the descriptor: `db_app_compose(&(const db_app_module_t*){&kyr_<word>_module}, 1)` gives your env ids after the core's with their names, class and schema, your capabilities in the core's registry, every reason found by token, every record handle variable; composing it twice is refused. An IT that compiles and links a composition root from the extracted `-dev` deb with the core and boots the module. And every route through the core's in-process harness: `db_app_init_modules({&kyr_<word>_module}, 1, slots)` on a fresh root (`DB_APP_DB_ROOT`, `DB_APP_KEYS_DIR`, `DB_APP_REPLAY_CACHE` under `build/tests/`), users seeded with `repo_user_create` and logged in through `POST /api/app/auth/login` with an Ed25519 device key (`jose_adapter_thumbprint`), each request through `db_app_run` with the bearer and a fresh DPoP proof (`htm`, `htu` = the request path without the query and without `/api/app/`, `iat`, `jti`, `ath`, `sid`) — the router, the guard and your handler exactly as in production. For each route: the allowed actor, then every refusal (no session 401, for a route with an id a proof signed for another id or for the bare prefix 400 bad_dpop, no product record, the other account kind, an object the actor may not see 404, the wrong role 403, each malformed body 400, each refused transition 409). kyr_estate's `tests/support/harness.h` is the pattern: header-only, with a recording fake behind the hook that refuses on demand.

10. **Reuse another module as a library** (the data room on drive) without pinning it: two tier-5 repositories may not pin each other (`deps.sh check --tiers`), no repository below kyr_server sees more than one module (plan §3), and the platform refuses a vertical that requires another vertical (`dbctl product validate`). Declare the hook as an ops struct in your own header in the shape of the library it will be bound to — for the data room, kyr_drive's `kyr/drive/room.h` (2.0.0): the core's `db_app_status_t`, 16-byte platform ids (`uint8_t[DB_APP_ID_SIZE]`), unix seconds, the library's argument order — so the edition assigns the library's functions directly and wraps only what differs (kyr_estate's `kyr/estate/rooms.h`: create, seal, usage and purge are the drive's functions, share maps one enum). `kyr_<word>_rooms_bind(const ops*)` is called by the edition's `modules.c` before the core boots; `boot` refuses while unbound. Map your own levels to what the library enforces in your repository (a public function, tested), never in the adapter, and convert units at the call (milliseconds to the library's seconds, rounded up). Your env holds the policy, the library the bytes and the enforcement, and no transaction spans the two: a looser change (new or higher access, later or no expiry) is written in your env first and applied through the hook second; a stricter one (lower access, an earlier expiry, a revoke) is applied first and written second; so a refusal between them leaves access stricter and the next write repairs it. Test both orders with the fake refusing, and let `check` report drift. The adapter itself is the edition's (step 17); write it in your notes and compile it against both debs in scratch before sending it.

11. **Declare the rights** (plan §3.5) in `docs/RIGHTS.md`, `caps.def` and `rights.h`: accounts, sessions and the platform role are the core's; every product role and scope (membership, grant, side, moderator) lives in your envs keyed by the platform uid. Each capability has a platform-role floor (the core's `db_app_role_t`: VIEWER 1, PUBLISHER 2, ADMIN 4, OWNER 128; a floor, never the capability) and the product condition that must also hold. A handler asks the core's policy first (`db_app_authz_can(db_app_policy_compiled(), role, cap_base + id, DB_APP_ROLE_INVALID, DB_APP_REL_NONE)`: registered, enabled, floor met), then the product's decision, one pure function over (capability, facts the caller read); a unit test walks the table, and the route tests of step 9 walk each refusal on the wire. Separation-of-duties rules are enforced in your own transactions.

12. **Write the web bundle** against `kyr-shell/2` (kyr-shell 1.1.0 or later) in `web/<word>/`: `bundle.js` with `contract: "kyr-shell/2",` on its own line, `id: "<word>"`, `html: "<word>/<word>.html"`, `nav` entries whose views (`<section id="view-<view>" class="view" hidden>`) exist in the fragment, are prefixed `<word>_` and are not shell views (`home nerd users system me admin`); imports only `../js/api.js`, `../js/proof.js`, `../js/format.js`, `../js/i18n.js`, `../js/links_api.js` and the bundle's own files; never `fetch` itself; no inline script, `on*=` or `style=`; files `.js .html .css .woff2` only; every call inside `ctx.authed()` with a fresh proof `buildDpopProof({ method, path })` over the same `path` string the request fetches: the shell's `htuOf(path)` computes the htu (pitfall 3), so a bundle never writes an `htu` of its own (the shell signs a legacy `htu` verbatim with a console.error, and `kyr-shell/3` drops the option). Nav `capability` gates only by the platform role through `/me`, so when every capability has the VIEWER floor leave it out and let each view gate itself on the product's own `GET <word>/me`. Signed-out pages (a public site) cannot be bundle views in kyr-shell/2: ship them as static pages under `web/<word>/site/`. No `data-i18n` keys until the shell has per-bundle dictionaries (its parity gate reads only its own). kyr-shell is tier 4, the web half of the core, so a product may pin it (1.1.0, its FINAL line in `$WS/_notes/kyr_shell.md`) and test its bundle against the real shell files; its deb ships the shell, not the composer or the checker, so check your side of the contract with a script of your own and an IT that also proves each refusal (kyr_estate: `tests/support/check_bundle.py`, `tests/ITs/web_bundle.sh`; known failure 1). Package it in `utils/build_deb.sh`, before `deb_sha256sums`:
   ```
   stage="$(deb_stage kyr-<word>-web share/kyr/web)"
   cp -a "${ROOT_DIR}/web/<word>" "${stage}/usr/local/share/kyr/web/<word>"
   find "${stage}/usr/local/share/kyr/web" -type f -exec chmod 0644 {} +
   deb_control "${stage}" kyr-<word>-web web all "kyr <word> web bundle (kyr-shell/2)"
   deb_copyright "${stage}" kyr-<word>-web
   deb_build "${stage}" kyr-<word>-web all
   ```
   and add the tree to the build inputs in `utils/kyr_<word>_project.sh`, `KYR_BUILD_INPUTS+=(web)`: the debs' `SOURCE_DATE_EPOCH` is the time of the last commit that touched an input, so a docs- or tests-only commit rebuilds the same bytes.

13. **Write the docs**: `docs/DOMAIN.md` (entities, relations, state machines, envs, the layout capture), `docs/RIGHTS.md`, `docs/WIRE.md` (every route under `/api/app/<word>/`, bodies, answers, errors, paging as io_rms: `limit` ∈ {10, 40, 80, 120}, opaque `after`, `{"items","has_more","next_after"}`, `400 cursor_invalid`), `docs/diagrams/*.puml` with one claim each (components, domain, rights, a request sequence, one state diagram per state machine, the hook), and a terse README, never hard-wrapped, with one line naming the diagrams.

14. **Run the gates**, from the sysroot, no sudo, nothing from `/usr/local`:
   ```
   ./utils/deps.sh sysroot && eval "$(./utils/deps.sh sysroot | grep '^export')"
   ./utils/run_pipeline.sh                   # deps-tiers, template, format, 6 profiles, UTs x audit/sanitize/release, ITs, package
   "$KYR_BUILD_DIR/template_check.sh" "$PWD"
   ```
   Done only at `pipeline GREEN`. One commit per step, message = what the change is.

15. **Freeze the ABI** once another repository pins the `-dev` deb: `./utils/check_abi.sh --update`, commit `abi/layout.txt` (a first layout needs no raise). From then on the pipeline's `abi` stage refuses, against the last `v<x.y.z>` tag, a changed or removed line or a member added to an existing struct without a raised major (raise VERSION's major and the linker map's node `KYR_<WORD>_<major>` together) and a new public name without a raised minor; `abi-exports` requires the library to export exactly the declared functions. What is public comes from `KYR_ABI_*` in the project file, defaulting to the `kyr_<word>_` prefix (each prefix setting may be a list). The gate has no 0.x rule (SemVer §4 is not applied): at major 0 a changed or removed line still needs a raised major, and without a tag the base is the previous commit, so the first contract change after the freeze makes a 0.x product `1.0.0` (kyr_estate: 0.1.0 → 1.0.0 when it moved onto the core, accepted). Keep a step's public-header changes in one commit: every later commit that adds a public name needs its own raised minor.

16. **Hand off** after the last commit (the debs' bytes depend on the last commit that touched a build input): `./utils/build_deb.sh && cp build/debs/*.deb ~/.cache/rh-deps/debs/ && cat build/debs/SHA256SUMS`, and give consumers the pin lines. Bump VERSION (SemVer) on any API or ABI change; a new record layout is a new `ver`, never an edit of an old one.

17. **The edition directory** (kyr_server, today DB_server; its owner makes the change, you send the files):
   ```
   editions/<word>/modules.c      the module array { &db_drive_module, &kyr_<word>_module } (the drive's descriptor keeps its name until the rename wave)
                                  and the hook bound over the library: kyr_<word>_rooms_bind(&ROOMS_ON_DRIVE) (kyr_estate's, in $WS/_notes/kyr_estate.md)
   editions/<word>/main.c         binds through modules.c, then boots the core over the array (db_app_init_modules(m, n, slots), or the host's main)
   editions/<word>/edition.def    FORMAT=1, EDITION=<word>, WEB_BUNDLES="shell <word>", one core process kyr-server-<word> (AUTH_REQUEST=no, MOUNT=/api/app),
                                  PROCESS_1_ENVS = core.user core.auth, the reused modules' envs, every <word>.* env; one ENV_n block each with SCHEMA and MIGRATION
   editions/<word>/site.schema    the config keys (the platform generates it: ops/gen_site_schema.sh)
   editions/<word>/routes.stream  the process's streamed routes (the reused module's upload lanes)
   editions/<word>/build          empty marker, once both module debs are pinned: utils/build_bin.sh builds the edition
   ```
   Check the edition.def before sending it with both parsers: `bash -c 'source $WS/DB_server/utils/lib/edition.sh && edition_load edition.def'` and `bash -c 'cd $WS/kyr_fleet && source lib/parse.sh && source lib/manifest.sh && edition_load <abs path>'`. In the edition repository: pin `libkyr-<word>-dev`, `libkyr-<word>` and `kyr-<word>-web` with sha256, and link `libkyr_<word>.a` and the reused module's archive before the core's, then `./utils/gen_edition.sh <word> && ./utils/check_editions.sh && ./utils/run_pipeline.sh`.

18. **The product line in the platform repository** (DB → kyr; its owner makes the change): `products/<word>/edition.def` and `site.schema` byte-identical to the edition's, `products/<word>/product.manifest` (`PRODUCT_STATE=planned` until the first bundle ships, `MODULES` with the kernel modules, the reused module and `<word>`, `WEB_BUNDLES="shell <word>"`, `PACKAGES="kyr-server-<word> kyr-<word>-web"`), `modules/<word>/module.manifest` (`TIER=vertical`, `REQUIRES` kernel modules only, `CAPABILITY` = every label of `caps.def`, `ENVS`, `WEB_BUNDLE`), the pins in `deps.txt`; then `./dbctl product validate <word> && ./ops/check_all.sh`. Try it first on a scratch copy (`git -C $WS/DB ls-files -z | tar --null -T - -cf - | tar -C <scratch> -xf -`).

19. **Build a bundle** (workstation, from the cache, no network). The web root, with the real shell:
   ```
   dpkg-deb -x ~/.cache/rh-deps/debs/kyr-shell_<ver>_all.deb sh && dpkg-deb -x ~/.cache/rh-deps/debs/kyr-<word>-web_<ver>_all.deb wb
   SOURCE_DATE_EPOCH=<platform tag commit time> $WS/kyr_shell/utils/compose_web.sh --shell sh/usr/local/share/kyr/shell \
       --bundle wb/usr/local/share/kyr/web/<word> --out web --product <word>
   python3 $WS/kyr_shell/utils/check_composed.py web <word>
   ```
   Then the bundle, once the edition binary's deb is pinned in the platform: `SOURCE_DATE_EPOCH=… $WS/kyr_fleet/bin/kyr-bundle build --edition <word> --from $WS/DB/deps.txt --cache ~/.cache/rh-deps/debs --editions-dir $WS/DB_server/editions --calver YYYY.MM.0 --seq 1 --web-root web --out bundles`, twice, hashes compared, then `kyr-bundle verify` and `fleet bundle sign … --namespace kyr-candidate`.

20. **The VM lane** (the owner; needs the VM): `fleet machine add vm rh@<vm> --edition <word> --environment test --channel candidate` → `fleet machine enroll vm` → `fleet provision vm` → `fleet site-env vm --bundle <b>` → `fleet plan vm --bundle <b>` → `fleet apply vm --plan <id>` → `fleet status vm`; then the platform's black-box suite, `tests/upgrade/run_matrix.sh` and `tests/restore/run_drill.sh`. For a client: one overlay per machine in kyr_fleet_inventory (checklist line 4).

21. **Process-based differences**: the repository implements the host descriptor (`kyr_host_main(argc, argv, &APP)`, pin `libkyr-host-dev`), mounts beside the core (`/api/<word>`), takes identity only from `X-Auth-User`, `X-Auth-Role`, `X-Auth-State`, `X-Auth-Session` (a request without them is `500 server_error`, never `401`; the bundle signs the full path, `<word>/…` after `/api/`, which the core's authz checks against `X-Original-URI`), owns exactly one env `<brand>.main`, and its `edition.def` process has `AUTH_REQUEST=yes`. The edition's `modules.c` is `{ }` when no module product shares the box.

## Known pitfalls (found building kyr_estate on the real core; 1, 2, 3 and 6 resolved in DB_app 2.1.0)

1. **The boot env is valid during `boot` only** (resolved in DB_app 2.1.0). `<db_app/module.h>` says so: the `const db_app_module_env_t*` that `boot` receives is valid for the call, and the struct is values only (env, capability, route and record bases, the slot count, your own descriptor), so a copy is complete and never dangles. Copy it (`booted = *env`) or ask `db_app_module_env(&kyr_<word>_module)` later, which answers the same values (slots included) while the composition lives; never keep the pointer. Since 2.1.0 the core hands `boot` its composed entry; before, it handed a temporary that the next module's boot overwrote, and estate's first harness run wrote to `core.auth`'s DBIs (`KID_TO_DEVICE_ID: key size 16 != fixed 32`) through a kept pointer.
2. **Listing resource tags come from the core's registry** (resolved in DB_app 2.1.0). `listing_query_t.resource_tag` binds a cursor to one list, so two modules on one tag would let a cursor minted by one list steer the other's walk. In `boot`, `db_app_listing_tags_reserve(&kyr_<word>_module, n, &base)` (a refusal fails the boot) gives a block no other module holds (handed out from 255 down to 128; asking again for the same n returns the same block); keep `base` with the copied env, name each list's tag `base + k` once in your code (a getter, never a literal) and never reorder them. The executor refuses a list under a core tag, under a registry tag nobody reserved, or over your env under another module's block. Tags 2..127 still run unchecked only for modules built before 2.1.0 (the drive's 2 and 3, kyr_estate's 34); a new product never uses them. Moving an existing list to the registry invalidates its outstanding cursors once (`400 cursor_invalid`, TTL 300 s).
3. **The DPoP `htu` is the full request path** (decision D33, resolved in DB_app 2.1.0 and kyr-shell 1.1.0). The core computes the expected htu with one function, `db_app_request_htu()`: the path without the query and without `/api/app/` (`/api/` on another mount), ids included, byte for byte (no slash or percent normalization), at most 127 bytes; its router guard, the authz subrequest (on `X-Original-URI`), login and refresh all call it, for every route. A proof for `<word>/properties/<A>` is `400 bad_dpop` on `<word>/properties/<B>`, a proof for the bare prefix `<word>/properties` opens neither, and the route table's htu column is informational. The bundle signs `buildDpopProof({ method, path })` (step 12); a handler that runs the guard itself (an upload data endpoint) passes `db_app_request_htu(req->path, htu)`; your WIRE.md states the rule, and route tests sign the full path and prove another id and the bare prefix refused. Before 2.1.0 the guard checked only a prefix route's fixed prefix, so one proof opened every id below it; a 2.0.0 core refuses a full-path proof, so a product moves to 2.1.0 and `kyr-shell/2` together.
4. **The guard's answers.** No `Authorization` is `401`; a proof for another `htu` or method is `400 bad_dpop`, not 401; a disabled account is `403 forbidden_state` before your handler runs.
5. **The response arena is 34 KiB** (`DB_APP_RESPONSE_ARENA_BYTES`) and the listing executor reserves 28 KiB of it for a page. Size a reservation by the real escape bound of what you stored: refuse control bytes except `\n` and `\t` on the way in, and stored text escapes to at most two bytes per byte; a reservation beyond the arena is a `500` (estate's longest answer, 8000 bytes that all escape, is tested).
6. **Request bodies go through the core's JSON reader** (resolved in DB_app 2.1.0). `<db_app/request/json.h>`: `db_app_json_parse(&doc, req->body.p, req->body.n, toks, cap, &limits)` into your token array, then `db_app_json_get/at/member/string/uint/int/bool/type`. Set the limits from your record bounds (`max_bytes` the body, `max_string` your longest text field's decoded bytes, `max_depth` your nesting, `max_tokens`, `no_escapes` where text never needs one; zero takes the default: 16384, 8192, 8, 512); an object holds at most `DB_APP_JSON_MEMBERS_MAX` (1024) members. Strict RFC 8259: UTF-8 checked, surrogates paired, `\u0000`, raw control bytes and duplicate keys refused, integers exact up to 2^53 − 1; fuzzed in the core. Map a refusal to your `400 bad_body`, and still refuse control bytes your text must not store (pitfall 5). `db_app_body_json_get_string` (flat, 512 bytes, no escapes) stays the core's admin reader; a product's own reader (kyr_estate's `app/src/json.c`, written before 2.1.0) is no longer needed.
7. **The ABI gate at 0.x** (step 15): a changed public line is a major even at 0.x; plan the first public-contract change as the product's 1.0.0.

## Known failures (the structure against bar test 1), each a request in `$WS/_notes/kyr_estate.md`

1. The product side of the shell contract (`kyr-shell/2`, as `/1` before) has no shared checker: the kyr-shell deb (1.1.0 too) ships the shell, not `compose_web.sh` or `check_composed.py`, so each product carries its own. Fix proposed: ship them (or a `check_bundle.py`) in the kyr-shell deb.
2. Fixed in DB_app 2.0.0 (1.41.0's content): records as wide as they declare, `DB_APP_RECORD_VARIABLE` in `migrate`, and a per-env map maximum (`env_map_max`, descriptor ABI 1.1). Formerly: 1024-byte record caps refused a product with prose, variable-length rows were rewritten by every `migrate`, and a module could not size one env apart from another.
