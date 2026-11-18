# node-pm — optimize-build stack reference
Use when: detect-stack.sh reported `node-pm`. Lanes: install, cache.

Checked 2026-11-09. Latest releases: npm **12.2.2**, pnpm **12.18.0** (11.28.x still patched), Yarn **4.18.1** (Classic 1.22.22), Bun **1.4.4**, `actions/setup-node` **v7.1.0**, `pnpm/setup` **v3.1.2**, `pnpm/action-setup` **v6.1.1**, `oven-sh/setup-bun` **v2.2.0**. Node 26.13.0 (LTS) still bundles **npm 11.20.0**, so npm 12 runs only where a workflow installs it. **(local)** means run that day on macOS against a one-dependency toy project (npm 11.20.0 and 12.2.2, pnpm 11.22.0, bun 1.3.14), so re-measure on the repo. Generic cache semantics (scope, eviction, the save-on-main-only pattern) are in `ci-github-caching.md`. Playwright browser installs are in `stack/playwright.md`.

## Measure
- **Which PM, which bootstrap:**
  ```bash
  ls package-lock.json npm-shrinkwrap.json pnpm-lock.yaml pnpm-workspace.yaml yarn.lock .yarnrc.yml .pnp.cjs bun.lock bun.lockb 2>/dev/null; ls -d .yarn/cache 2>/dev/null
  jq '{packageManager, devEngines, workspaces, allowScripts, trustedDependencies, dependenciesMeta, scripts: (.scripts|with_entries(select(.key|test("install|prepare"))))}' package.json
  grep -nE 'npm (ci|install|i)\b|pnpm (i|install|ci|fetch)\b|yarn( install| workspaces focus)?\b|bun (ci|install)|corepack|--ignore-scripts|--no-audit|--filter|-w ' .github/workflows/*.y*ml
  grep -nE 'setup-node|pnpm/(action-)?setup|setup-bun|actions/cache|cache(-dependency-path)?:|package-manager-cache|save-cache|install:|run_install' .github/workflows/*.y*ml
  grep -rlE '"(cypress|puppeteer|electron|@playwright/browser-[a-z]+)"' --include=package.json . | grep -v node_modules
  ```
- **CI split.** The cache restore runs *inside* the `Setup Node` / `pnpm/setup` / `pnpm/action-setup` step, and the save runs in its `Post …` step (`post-if: success()`, so a failed job saves nothing) ([setup-node action.yml](https://github.com/actions/setup-node/blob/main/action.yml)). Take step durations from the jobs JSON (`ci-github-timings.md`), then read the log: `Cache restored from key:` / `<pm> cache is not found` / `Cache Size: ~N MB` / `Cache saved with the key:`.
- **npm phases:** `npm ci --timing --silent --logs-dir="$RUNNER_TEMP/npm-logs"` writes `*-timing.json` with a `timers` object in ms ([logging](https://docs.npmjs.com/cli/v12/using-npm/logging)). Upload the directory as an artifact, then rank it:
  `jq -r '.timers|to_entries[]|"\(.value)\t\(.key)"' "$RUNNER_TEMP"/npm-logs/*-timing.json | sort -nr | head -15`
  The keys to read are `npm-ci:rm` (wiping `node_modules`), `idealTree`, `reify:unpack` (extraction), `reify:build` (lifecycle scripts) and `reify:audit` (the audit POST). (local, same key names on 11.20.0 and 12.2.2)
- **npm cache hits:** `npm ci --loglevel=http` prints `npm http fetch GET 200 <url> <ms> (cache miss)` for every tarball it downloads and `npm http cache <spec> 0ms (cache hit)` for every reuse. Compare `grep -c '(cache miss)'` with `grep -c '(cache hit)'` (local).
- **pnpm:** in CI the reporter is `append-only` (non-TTY default) ([install](https://pnpm.io/cli/install)). The last progress line is `Progress: resolved N, reused N, downloaded N, added N, done`, then `Done in Xs using pnpm vX`. `reused` counts store hits and `downloaded` counts misses (local). For phases, run `--reporter=ndjson` and read the `pnpm:stage` events (`resolution_started/_done`, `importing_started/_done`, each with an epoch-ms `time`). A frozen headless install emits only the importing events (local). pnpm ≥11.6 logs `Lockfile passes supply-chain policies (verified … ago)` when it reused a verification verdict. On a warm store, if that line is missing, the job paid for verification again (Check 4).
- **Yarn Berry:** each phase prints `┌ Resolution step` / `Fetch step` / `Link step` / `Post-install validation` and closes with `└ Completed in …`. The run ends with `Done in …` or `Done with warnings in …` ([Project.ts](https://github.com/yarnpkg/berry/blob/master/packages/yarnpkg-core/sources/Project.ts), [StreamReport.ts](https://github.com/yarnpkg/berry/blob/master/packages/yarnpkg-core/sources/StreamReport.ts)). A long Fetch step means a cache miss. A long Link step means builds or many files.
- **Bun:** prints `N packages installed [Xms]` (local); add `--verbose` for detail.
- **Local cold vs warm** (never delete the user's real cache): `hyperfine --runs 3 --prepare 'rm -rf node_modules' 'npm ci --no-audit' 'npm ci --no-audit --cache "$(mktemp -d)"'`. The second command gets a fresh empty cache on every run. For pnpm use `--store-dir "$(mktemp -d)"`.

## Checks
**1. Not a frozen install, or installing twice.** **Check** the install lines from Measure. **Good** `npm ci`. `pnpm install` freezes on its own in CI when a lockfile exists; `pnpm ci` (≥11) runs `pnpm clean` and then a frozen install. `yarn install` (Berry) has `--immutable` on in CI. Classic needs `yarn install --frozen-lockfile`. Bun needs `bun ci` (= `bun install --frozen-lockfile`), because Bun does **not** freeze on its own in CI ([bun install](https://bun.com/docs/pm/cli/install)). Exactly one install per job.
**Fix** Replace `npm install` with `npm ci`. Any tree-shaping flag used to write the lock (`legacy-peer-deps`, `install-links`) must also be passed to `npm ci`, so commit it to the project `.npmrc` ([npm ci](https://docs.npmjs.com/cli/v12/commands/npm-ci)). `pnpm/setup@v3` runs `pnpm install` by default (`install: 'true'`), so either delete the separate `pnpm install` step or set `install: false` ([action.yml](https://github.com/pnpm/setup/blob/main/action.yml)). With no lockfile at all, `pnpm install` resolves, writes a lockfile and exits 0; `require-lockfile: true` turns that into a failure ([pnpm/setup](https://github.com/pnpm/setup)).
**Gain** Mostly correctness. A duplicate install costs one install step, measured. **Risk** None. A lock/manifest mismatch now fails the job, which is the point. A lockfile written by a newer pnpm major also fails the install ("instead of silently rewriting it"), so declare the pnpm version once in `packageManager` or `devEngines.packageManager` ([pnpm CI](https://pnpm.io/continuous-integration)).

**2. No package-manager cache.** **Check** the install job has no `cache:`, no `actions/cache` on the PM directory, and no `pnpm/setup` `cache: true`. setup-node v6+ auto-caches **npm only**, and only when `packageManager`/`devEngines.packageManager` says npm. Yarn and pnpm need `cache:` set ([setup-node](https://github.com/actions/setup-node)). `setup-bun` caches only the Bun binary (`no-cache` input) ([action.yml](https://github.com/oven-sh/setup-bun/blob/main/action.yml)). **Good** One cache per PM directory (see Cache paths), restored before install, with no second cache on the same directory. setup-node caches the PM's global cache, never `node_modules`.
**Fix**
  - setup-node: `cache: npm|yarn|pnpm`. For pnpm, pnpm must be on PATH before setup-node, because it runs `pnpm store path --silent`.
  - pnpm ≥11: prefer `pnpm/setup@v3` `cache: true`. Its `cache-hit` output is true only for an exact lockfile match.
  - pnpm ≤10: `pnpm/action-setup@v6` with `cache: true` and `cache_dependency_path`.
  - Bun: `actions/cache` on `~/.bun/install/cache`, keyed on `bun.lock`.
**Gain** The download share of the install: the `(cache miss)` count, or pnpm's `downloaded N`. Typical, unmeasured. pnpm itself warns that store caching "is not guaranteed" to be faster ([pnpm CI](https://pnpm.io/continuous-integration)). **Risk** A large store restored from a slow cache can lose to a fast registry, so compare the restore step against a cold install. Never let untrusted jobs write to the cache. setup-node recommends `package-manager-cache: false` for workflows with elevated privileges.

**3. Every lockfile change is a cold install.** **Check** setup-node `cache:` keys on `node-cache-<RUNNER_OS>-<arch>-<pm>-<hashFiles(lock)>` with **no restore-keys**. The one exception is Yarn Berry with `enableGlobalCache: false` and no committed `.yarn/cache`. `cache-hit` is `true` on any restore ([cache-restore.ts](https://github.com/actions/setup-node/blob/main/src/cache-restore.ts), [cache-utils.ts](https://github.com/actions/setup-node/blob/main/src/cache-utils.ts)). **Good** A partial restore on lockfile bumps.
**Fix** Use `package-manager-cache: false` plus `actions/cache/restore` with a `restore-keys` prefix (fix A in `ci-github-caching.md`). Or use `pnpm/action-setup@v6` (`pnpm-cache-<OS>-<arch>-<hash>`, prefix fallback, then `pnpm store prune` before the save). Or use `pnpm/setup@v3`, which restores the newest entry, prunes, and saves only if the store's package set changed ([pnpm/setup](https://github.com/pnpm/setup)).
**Gain** Only on lockfile-changing runs. Typical, unmeasured. **Risk** Prefix restores grow the store, so prune before saving. Use prefix restores only for download caches, never for `node_modules`.

**4. pnpm ≥11: the lockfile verification verdict is not cached.** **Check** pnpm ≥11, and the only cache is the store (setup-node `cache: pnpm`, `pnpm/action-setup`, or `actions/cache` on `pnpm store path`), and the log lacks `Lockfile passes supply-chain policies`. **Good** `$(pnpm cache path)` (≥11.21) is restored too. It holds `lockfile-verified.jsonl` ([cache path](https://pnpm.io/cli/cache-path)). `pnpm/setup@v3` restores and saves it automatically under `pnpm-lockfile-verified-<OS>-<arch>-<lockhash>`, even with `cache: false`.
**Fix** Switch to `pnpm/setup@v3`, or add `pnpm cache path` to the cache `path`. **Gain** 13.5 s → 1.5 s with `minimumReleaseAge` + `trustPolicy`, and 6.7 s → 1.6 s without policies, on ~2000 lockfile entries with a warm store (vendor, [pnpm/setup README](https://github.com/pnpm/setup)). pnpm docs call this check "the dominant cost of an install in CI once the store is warm". **Risk** The file records policy verdicts, so write it only from trusted jobs.

**5. npm extras on every install.** **Check** `npm ci` without `--no-audit`, and a large `reify:audit` timer. **Good** `npm ci --no-audit --no-fund`, or `audit=false` and `fund=false` in the project `.npmrc`. The audit runs in its own scheduled or PR job. **Gain** The `reify:audit` timer: (local) 225 ms of a 312 ms install for one dependency, a POST to `/-/npm/v1/security/advisories/bulk` that grows with the tree. `fund` only prints. **`--prefer-offline` on `npm ci`:** (local, 12.2.2) with a lockfile and a warm cache, `npm ci` made zero registry requests with or without the flag, so claim no gain unless `--loglevel=http` shows `(cache miss)` lines it removes. **Risk** The job no longer reports advisories.

**6. Dependency scripts download binaries the job never uses.** **Check** which dependency scripts actually run:
  - npm ≤11 runs all of them. npm 12 runs only packages in `allowScripts`.
  - pnpm ≥10 runs only packages allowed by `allowBuilds` (≥11; `onlyBuiltDependencies` in v10).
  - Yarn ≥4.14 defaults to `enableScripts: false`, with per-package `dependenciesMeta` exceptions.
  - Bun runs a built-in allowlist that includes `cypress`, `puppeteer`, `electron`, `esbuild` and `sharp` ([lifecycle](https://bun.com/docs/pm/lifecycle), [list](https://github.com/oven-sh/bun/blob/main/src/install/default-trusted-dependencies.txt)). Setting `trustedDependencies` replaces that list.

  Cross that with the download packages grep. **Good** Jobs that don't run E2E or Electron skip the downloads.
**Fix** Set env on those jobs:
  - `CYPRESS_INSTALL_BINARY=0` ([Cypress](https://docs.cypress.io/app/references/advanced-installation)).
  - `PUPPETEER_SKIP_DOWNLOAD=true`, or the per-browser `PUPPETEER_CHROME_SKIP_DOWNLOAD` ([Configuration](https://pptr.dev/api/puppeteer.configuration)).
  - `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, which matters only for `@playwright/browser-*` packages.

  Electron ≥42 no longer downloads in `postinstall`, and `ELECTRON_SKIP_BINARY_DOWNLOAD` is unsupported there. To skip every dependency script, use `--ignore-scripts` (npm, pnpm, bun; it skips the root `prepare` too) or Yarn `--mode=skip-build`. Jobs that need a binary cache it keyed on the tool's version, not the lockfile.
**Gain** The binary download and extract time per job. Typical, unmeasured: confirm with `reify:build` (npm) or the Link step (Yarn). **Risk** A job that does need the binary fails at runtime. `--ignore-scripts` also leaves native addons unbuilt.

**7. Monorepo jobs install the whole workspace.** **Check** a `workspaces` field or `pnpm-workspace.yaml`, plus per-app jobs that run a full install. **Good** Each job installs its slice:
  - pnpm: `pnpm install --filter <app>...` (`...` adds the app's dependencies) ([filtering](https://pnpm.io/filtering)). Before 10.28, a filtered install could be slower than a full one ([10.28](https://pnpm.io/blog/releases/10.28)).
  - npm: `npm ci -w <ws>` installs only that workspace and its dependencies. Root `devDependencies` come along only with `--include-workspace-root` (local, 11.20.0 and 12.2.2).
  - Yarn Berry: `yarn workspaces focus <ws> [--production]`, bundled since 4.0 ([focus](https://yarnpkg.com/cli/workspaces/focus)).
  - Bun: `bun install --filter <pkg>`.
  - Docker: `pnpm fetch` needs only the lockfile, then `pnpm install -r --offline` ([fetch](https://pnpm.io/cli/fetch)).

  **Gain** Proportional to the dependencies skipped. Unmeasured. **Risk** Root tooling (eslint, turbo) disappears. Tasks that read other workspaces break. Keep a full install on `main`.

**8. Yarn Berry slow paths.** **Check** `.yarnrc.yml` has `compressionLevel: mixed`. 4.0 wrote it automatically for zero-install repos migrating from 3.x. Also check whether PR installs on a public repo are slower than push installs: `enableHardenedMode` defaults on "on GitHub pull requests from public repository" and queries the registry to validate the lockfile, and "these checks make installs slower" ([yarnrc](https://yarnpkg.com/configuration/yarnrc)).
**Fix** `compressionLevel: 0`, the 4.0 default, "significantly faster" ([CHANGELOG 4.0](https://github.com/yarnpkg/berry/blob/master/CHANGELOG.md)). For hardened mode, set `YARN_ENABLE_HARDENED_MODE=0` only when `github.event.pull_request.head.repo.full_name == github.repository`. **Gain** Typical, unmeasured: compare the Resolution step on PR runs and push runs. **Risk** The compression change rewrites every cache archive once and churns a committed `.yarn/cache`. Never disable hardened mode for fork PRs.

**9. Broken PM bootstrap.** **Check** `corepack enable` on Node ≥25: Corepack is no longer bundled from v25 ([Node docs](https://nodejs.org/download/release/v25.8.0/docs/api/corepack.html)). pnpm's docs say "Do not use Corepack. It runs pnpm through a Node.js shim on every call" ([pnpm CI](https://pnpm.io/continuous-integration)). Also check setup-node `cache: yarn` placed before Yarn Berry is resolvable. setup-node runs `yarn --version` and caches `yarn cache dir` (the Classic path) when the version is 1.x, otherwise `yarn config get cacheFolder` ([cache-utils.ts](https://github.com/actions/setup-node/blob/main/src/cache-utils.ts)).
**Fix** For pnpm, use `pnpm/setup@v3` or `pnpm/action-setup@v6`. For Yarn, run `npm i -g corepack` before `corepack enable` on Node ≥25, or commit `yarnPath`, and do it *before* setup-node. **Gain** Correctness: the right directory gets cached. Shim overhead is unmeasured. **Risk** Low.

**10. `node_modules` restored, then reinstalled.** **Check** `actions/cache` on `node_modules` followed by an unconditional `npm ci`. `npm ci` deletes an existing `node_modules` first (the `npm-ci:rm` timer). **Good** No `node_modules` cache. Or an exact key `nm-<os>-<arch>-node<ver>-<lockhash>` with **no** restore-keys and `if: steps.nm.outputs.cache-hit != 'true'` on the install. The full YAML is in `ci-github-caching.md` §5. **Gain** Install time minus restore time, so measure both. **Risk** Native addons are tied to the Node ABI. Downloads outside the tree (`~/.cache/Cypress`) are not captured. The archive is usually larger than the store.

## Cache paths
Always ask the tool for the path instead of hard-coding it. Restore **before** install. Save in a post step, only on success, and ideally only from the default branch.

| What | Path | Key inputs | Notes |
|---|---|---|---|
| npm | `npm config get cache`: `~/.npm`, or `%LocalAppData%\npm-cache` on Windows ([config](https://docs.npmjs.com/cli/v12/using-npm/config#cache)) | OS, arch, `package-lock.json` | Logs default to `<cache>/_logs`, so pass `--logs-dir` outside the cache. `npm ci` wipes `node_modules`, not the cache. |
| pnpm store | `pnpm store path` (versioned, e.g. `…/store/v11`). Defaults: `$PNPM_HOME/store`, `$XDG_DATA_HOME/pnpm/store`, `~/.local/share/pnpm/store` on Linux, `~/Library/pnpm/store` on macOS, `~/AppData/Local/pnpm/store` on Windows ([store](https://pnpm.io/settings/store)) | OS, arch, `pnpm-lock.yaml` | On another disk the store is copied instead of hardlinked. pnpm 12 falls back to `<project>/node_modules/.pnpm-store` when no directory above the project accepts hardlinks. Prune before saving. |
| pnpm metadata | `pnpm cache path` (≥11.21) | same as the store | Holds `lockfile-verified.jsonl` (Check 4). |
| Yarn Berry | `yarn config get cacheFolder` returns `<globalFolder>/cache` = `~/.yarn/berry/cache` while `enableGlobalCache: true` (the 4.x default), otherwise `.yarn/cache` ([Configuration.ts](https://github.com/yarnpkg/berry/blob/master/packages/yarnpkg-core/sources/Configuration.ts)) | OS, `yarn.lock` | A committed `.yarn/cache` (zero-installs) leaves nothing to cache. `nodeLinker` defaults to `pnp`, which means no `node_modules`. |
| Yarn Classic | `yarn cache dir` (or `YARN_CACHE_FOLDER`) | OS, `yarn.lock` | |
| Bun | `~/.bun/install/cache`, `BUN_INSTALL_CACHE_DIR`, or bunfig `[install.cache] dir` ([global cache](https://bun.com/docs/pm/global-cache)) | OS, arch, `bun.lock` (plus `bun.lockb` while migrating) | |
| Cypress binary | `~/.cache/Cypress` (Linux), `~/Library/Caches/Cypress` (macOS), or `CYPRESS_CACHE_FOLDER` | Cypress version | |
| Puppeteer browsers | `~/.cache/puppeteer` (since v19), or `PUPPETEER_CACHE_DIR` | Puppeteer version | |
| Electron binary | `~/.cache/electron/` (Linux, or `$XDG_CACHE_HOME`), `~/Library/Caches/electron/` (macOS), or `electron_config_cache` ([install](https://www.electronjs.org/docs/latest/tutorial/installation)) | Electron version | |

Action keys:
- setup-node: `node-cache-<OS>-<arch>-<pm>-<hash>`, with no fallback. There is no save toggle, so it also saves from PR runs. To stop that, use `package-manager-cache: false` plus a manual `actions/cache/restore`.
- `pnpm/action-setup`: `pnpm-cache-<OS>-<arch>-<hash>`, falling back to the `pnpm-cache-<OS>-<arch>-` prefix ([run.ts](https://github.com/pnpm/action-setup/blob/master/src/cache-restore/run.ts)).
- `pnpm/setup`: a unique key per save, restoring the newest entry for the lockfile. `save-cache: false` makes it restore-only.

## Version traps
- **setup-node:** v5 enabled auto-caching for any detected PM and moved to the node24 runtime (runner ≥2.327.1). v6 limited auto-caching to npm (via `packageManager`/`devEngines.packageManager`). v7 is ESM and removed the dummy `NODE_AUTH_TOKEN` (Yarn Classic plus `registry-url` may now fail). v7 exposes `cache-primary-key` and `cache-matched-key` ([README](https://github.com/actions/setup-node)).
- **npm 12.0.0 (2026-07-08)** ([release](https://github.com/npm/cli/releases/tag/v12.0.0)):
  - Needs Node `^22.22.2 || ^24.15.0 || >=26.0.0`.
  - Dependency lifecycle scripts are blocked unless listed in `allowScripts`, managed with `npm install-scripts approve` (the docs also list `npm approve-scripts`). A faster install after the upgrade can just mean builds were skipped.
  - `allow-git` and `allow-remote` default to `none`.
  - **Unknown CLI flags throw.** `npm ci --frozen-lockfile` was a warning on 11.20.0 and is `EUNKNOWNCONFIG` on 12.2.2 (local).
  - `npm-shrinkwrap.json` is no longer honored, so rename it to `package-lock.json`.
  - Still warning-only on 12.2.2: `--production`, `--only`, `--also`, `--no-optional` (use `--omit=dev`/`--include=…`) (local).
- **pnpm 10 (2025-01):** dependency scripts are off by default.
- **pnpm 11 (2026-04-28)** ([release](https://github.com/pnpm/pnpm/releases/tag/v11.0.0)):
  - Needs Node ≥22.
  - `allowBuilds` (in `pnpm-workspace.yaml`) replaces `onlyBuiltDependencies`, `neverBuiltDependencies`, `ignoredBuiltDependencies` and `onlyBuiltDependenciesFile`.
  - `strictDepBuilds: true` fails the install on unreviewed build scripts ([build settings](https://pnpm.io/settings/build)).
  - **`.npmrc` is read for auth and registry only.** Other settings live in `pnpm-workspace.yaml` or the global `config.yaml`, and `npm_config_*` env vars are ignored, so use `pnpm_config_*`.
  - Store v11 uses a SQLite `index.db`, so caches saved by v10 miss.
  - New defaults: `optimisticRepeatInstall: true` and `minimumReleaseAge: 1440`.
  - Adds `pnpm ci`. 11.21 adds `pnpm cache path`.
- **pnpm 12 (2026-08-26)** ([release](https://github.com/pnpm/pnpm/releases/tag/v12.0.0)):
  - `--frozen-lockfile false` is rejected, so use `--no-frozen-lockfile`.
  - An unknown `pnpm-workspace.yaml` key fails when the project pins a matching pnpm.
  - On Linux, `packageImportMethod: auto` tries hardlinks first.
  - 12.7.0 adds `--allow-build`.
- **pnpm actions:** `pnpm/setup@v3` installs only pnpm ≥11, and pnpm 11 has no `darwin-x64` binary. For pnpm ≤10, use `pnpm/action-setup`.
- **Yarn:**
  - 2.0 renamed `--frozen-lockfile` to `--immutable`; the alias "will be removed in a later release".
  - 3.0 renamed `--skip-builds` to `--mode=skip-build`.
  - 4.0: Node ≥18.12, `enableGlobalCache: true`, `compressionLevel: 0`, official plugins bundled.
  - **4.14.0 (2026-04-16): `enableScripts: false` is the default.**
  - 4.15.0 ignores `YARN_IGNORE_SCRIPTS` ([releases](https://github.com/yarnpkg/berry/releases)).
- **Bun:** 1.2 made the text `bun.lock` the default (`bun.lockb` before). New workspaces default to the `isolated` linker (`configVersion = 1`, 1.3.2+), while existing lockfiles stay `hoisted` ([isolated installs](https://bun.com/docs/pm/isolated-installs)).
- **Others:**
  - Node 25+ ships without Corepack.
  - Electron 42 dropped the `postinstall` download and `ELECTRON_SKIP_BINARY_DOWNLOAD` ([breaking changes](https://github.com/electron/electron/blob/main/docs/breaking-changes.md)).
  - Playwright 1.38 stopped downloading browsers on `npm install`, except `@playwright/browser-*` ([v1.38.0](https://github.com/microsoft/playwright/releases/tag/v1.38.0)).

## Sources
- npm: [npm ci](https://docs.npmjs.com/cli/v12/commands/npm-ci), [config](https://docs.npmjs.com/cli/v12/using-npm/config), [logging](https://docs.npmjs.com/cli/v12/using-npm/logging), [workspaces](https://docs.npmjs.com/cli/v12/using-npm/workspaces), [v12.0.0 release](https://github.com/npm/cli/releases/tag/v12.0.0), [v12 changelog post](https://github.blog/changelog/2026-06-24-upcoming-breaking-changes-for-npm-v12/), [install-scripts](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-install-scripts.md)
- setup-node: [README](https://github.com/actions/setup-node), [advanced usage](https://github.com/actions/setup-node/blob/main/docs/advanced-usage.md), [cache-restore.ts](https://github.com/actions/setup-node/blob/main/src/cache-restore.ts), [cache-utils.ts](https://github.com/actions/setup-node/blob/main/src/cache-utils.ts), [cache-save.ts](https://github.com/actions/setup-node/blob/main/src/cache-save.ts); [actions/cache Node examples](https://github.com/actions/cache/blob/main/examples.md)
- pnpm: [CI](https://pnpm.io/continuous-integration), [install](https://pnpm.io/cli/install), [ci](https://pnpm.io/cli/ci), [clean](https://pnpm.io/cli/clean), [fetch](https://pnpm.io/cli/fetch), [filtering](https://pnpm.io/filtering), [store settings](https://pnpm.io/settings/store), [cache path](https://pnpm.io/cli/cache-path), [10.28](https://pnpm.io/blog/releases/10.28), [v11.0.0](https://github.com/pnpm/pnpm/releases/tag/v11.0.0), [v12.0.0](https://github.com/pnpm/pnpm/releases/tag/v12.0.0), [pnpm/setup](https://github.com/pnpm/setup), [pnpm/action-setup](https://github.com/pnpm/action-setup)
- Yarn: [yarnrc](https://yarnpkg.com/configuration/yarnrc), [install](https://yarnpkg.com/cli/install), [workspaces focus](https://yarnpkg.com/cli/workspaces/focus), [CHANGELOG](https://github.com/yarnpkg/berry/blob/master/CHANGELOG.md), [4.14.0](https://github.com/yarnpkg/berry/releases/tag/%40yarnpkg%2Fcli%2F4.14.0), [Classic cache](https://classic.yarnpkg.com/en/docs/cli/cache), [Classic install](https://classic.yarnpkg.com/en/docs/cli/install)
- Bun: [install](https://bun.com/docs/pm/cli/install), [global cache](https://bun.com/docs/pm/global-cache), [lifecycle](https://bun.com/docs/pm/lifecycle), [isolated installs](https://bun.com/docs/pm/isolated-installs), [setup-bun](https://github.com/oven-sh/setup-bun)
- Downloads: [Puppeteer configuration](https://pptr.dev/api/puppeteer.configuration), [Cypress advanced installation](https://docs.cypress.io/app/references/advanced-installation), [Electron installation](https://www.electronjs.org/docs/latest/tutorial/installation), [Playwright browsers](https://playwright.dev/docs/browsers), [Node corepack](https://nodejs.org/download/release/v25.8.0/docs/api/corepack.html)
