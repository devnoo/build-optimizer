# lint — optimize-build stack reference

Use when: detect-stack.sh reported `lint`. Lanes: typecheck-lint, cache.

Checked on 2026-11-09. **(cited)** means a linked vendor or maintainer number. **(local)** means it was run on 2026-11-09 against eslint 10.14.0, typescript-eslint 8.72.1 (with typescript 6.0.3), oxlint 1.93.0 and @biomejs/biome 2.6.6, on small synthetic repos, so re-measure on the real repo. **(heuristic)** means typical but unmeasured. Latest on npm: eslint 10.14.0, typescript-eslint 8.72.1 (peer `typescript >=4.8.4 <6.1.0`), oxlint 1.93.0, oxlint-tsgolint 7.0.2006, eslint-plugin-oxlint 1.93.0, @biomejs/biome 2.6.6, prettier 3.9.10, eslint-plugin-import 2.32.0, eslint-plugin-import-x 4.18.1. Run `npm ls eslint typescript-eslint oxlint @biomejs/biome` first.

## Measure

```bash
grep -nE 'eslint|oxlint|biome|prettier' package.json */*/package.json .github/workflows/*.y*ml
grep -rnE 'projectService|project:|allowDefaultProject|extraFileExtensions|TypeChecked|eslint-plugin-prettier|import(-x)?/|@stylistic' eslint.config.* 2>/dev/null
TIMING=1 npx eslint . -o /dev/null                    # top-10 rules (TIMING=all / TIMING=50 for more), table on stdout
npx eslint . --stats -f json -o eslint-stats.json     # per file, per pass: parse / rules / fix / total (ESLint >=9.0)
jq -r '.[] | [((.stats.times.passes|map(.total)|add)|floor), ((.stats.times.passes|map(.parse.total//0)|add)|floor), .filePath] | @tsv' eslint-stats.json | sort -rn | head -15
jq '[.[]|.stats.times.passes[]] | {parse:(map(.parse.total//0)|add), rules:(map((.rules//{})|[.[].total]|add//0)|add), fix:(map(.fix.total)|add)}' eslint-stats.json
```
- **TIMING.** It covers rule creation and execution only, not parsing ([custom rules](https://eslint.org/docs/latest/extend/custom-rules)). The table goes to **stdout**, so `>/dev/null` hides it; use `-o /dev/null` (local). Profile one rule with `TIMING=1 eslint --no-config-lookup --rule '<rule>: 2' <dir>`.
- **parse ≫ rules means the cost is the TS program, not rules.** With typed linting, building the program is counted in the `parse` time of the first file of each tsconfig: 311 of 380 ms in one file (local). Pruning rules will not fix that; fix the program (L3–L6). "a project's first type-aware lint rule will almost always seem the slowest", so compare typed rules one at a time ([tseslint perf](https://typescript-eslint.io/troubleshooting/typed-linting/performance/)).
- **typescript-eslint program path.** `DEBUG='typescript-eslint:*' npx eslint <files> -o /dev/null 2>&1 | grep -E 'single-run Program|default project'`. One `Creating single-run Program for project service: <tsconfig>` per tsconfig is the fast path. If you see none with `projectService`, it fell back (L5) (local, 8.72.1).
- **ESLint cache hit rate.** `DEBUG=eslint:eslint-helpers,eslint:lint-result-cache npx eslint … 2>&1 | grep -cE "Skipping file since it hasn't changed"` counts hits; `Cache entry not found or no longer valid` counts misses (local).
- **Threads.** `DEBUG=eslint:eslint` prints `Linting using N worker thread(s).` or `Linting in single-thread mode.` `ESLintPoorConcurrencyWarning` on stderr means the workers are slowing the run down (local, 10.14.0).
- **Oxlint.** `npx oxlint --debug=timings -f default` prints `Finished in Xms on N files with R rules using T threads.` and a `Rule timings:` table on stdout. Pass `-f default` explicitly. In 1.93.0, `GITHUB_ACTIONS=true` auto-selects the `github` format and agent shells get a compact format; neither prints timings (local). `--threads=INT` sets the thread count ([CLI](https://oxc.rs/docs/guide/usage/linter/cli.html)).
- **Biome.** `biome lint --profile-rules` (or `check`, Biome ≥2.4.0; not available on `ci`). It "excludes the time spent preparing the analysis, such as building the semantic model". `--profile-type-inference` profiles the types domain. The last line, `Checked N files in Xms`, is the wall time ([CLI](https://biomejs.dev/reference/cli/)).
- **CI logs.** Get the step durations from `ci-github-timings.md`. Compare the ESLint step against the `tsc` step: typed lint "should be roughly the same as your build times" ([tseslint perf](https://typescript-eslint.io/troubleshooting/typed-linting/performance/)). If lint is much slower than tsc, the cost is rules or plugins. If it is close to tsc, the cost is the program.

## Checks

**L1 ESLint cache unusable in CI**
- **Check:** `grep -rnE 'eslint[^|]*--cache' package.json .github/workflows/`. Look for a missing `--cache-strategy content`, a missing `actions/cache` for the location, or typed rules in the config.
- **Good:** untyped config, with `--cache --cache-strategy content --cache-location .cache/eslint/` restored by `actions/cache` (see Cache paths).
- **Fix:** add `--cache-strategy content`. The default, `metadata`, uses mtime, and "git does not track file modification time" ([CLI](https://eslint.org/docs/latest/use/command-line-interface)). After `touch`, metadata gave 0 hits and content gave all hits (local).
- **Gain:** proportional to the share of unchanged files (heuristic).
- **Risk:** the cache "does not track dependencies between files", so cross-file rules (`import/*`, typed rules) report stale results ([CLI](https://eslint.org/docs/latest/use/command-line-interface)). typescript-eslint: "We don't recommend using `--cache`" ([FAQ](https://typescript-eslint.io/troubleshooting/faqs/eslint)). Keep a cache-free full lint on `main`/`merge_group`.

**L2 Cache deleted inside the job**
- **Check:** list every `eslint` call in the job's scripts. Running without `--cache` but with the same `--cache-location` deletes that cache file (local). A run without either option only deletes `.eslintcache` ([CLI](https://eslint.org/docs/latest/use/command-line-interface)).
- **Fix:** give every invocation the same cache flags, or a separate location. **Gain:** the saved cache becomes usable. **Risk:** none.

**L3 Typed linting where it buys nothing**
- **Check:** `grep -nE 'TypeChecked|projectService|project:' eslint.config.*`, and look for typed configs that match `**/*.js`, config files or scripts.
- **Good:** typed configs scoped to `**/*.{ts,tsx}`, plus `{ files: ['**/*.js'], extends: [tseslint.configs.disableTypeChecked] }` ([configs](https://typescript-eslint.io/users/configs/)).
- **Gain:** "Running typed linting on a project is generally as slow as type checking that same project" ([perf](https://typescript-eslint.io/troubleshooting/typed-linting/performance/)), so each file you drop from the program saves type-check time (heuristic).
- **Risk:** JS files lose the typed rules.

**L4 `parserOptions.project` globs / wide tsconfig `include`**
- **Check:** `project:` with `**` globs, or a linted tsconfig with no `include` ("the same as providing the widest glob").
- **Fix:** `projectService: true` (stable since v8.0; v6/v7 called it `EXPERIMENTAL_useProjectService`), or `project` globs with a single `*`, and a targeted `include` ([perf](https://typescript-eslint.io/troubleshooting/typed-linting/performance/), [parser](https://typescript-eslint.io/packages/parser/)).
- **Gain:** wide `**` globs cause "much more disk IO than expected" (unquantified). The switch alone is not a speedup on one tsconfig. On 1024 files, `project` took 6.825 s; `projectService` took 7.204 s before 8.72.1 and 6.843 s from 8.72.1 on (cited, [PR #12988](https://github.com/typescript-eslint/typescript-eslint/pull/12988)). Monorepos with project references are "significantly faster" ([blog](https://typescript-eslint.io/blog/project-service)) (unquantified).
- **Risk:** each file uses its nearest `tsconfig.json`. Files outside every tsconfig error out.

**L5 Project-service fast path lost**
- **Check:** `allowDefaultProject` is non-empty, `extraFileExtensions` is set (Vue/Svelte), or the tsconfig has `references`. With any of these, 8.72.1 skips the single-run Program and uses the project service for that config (local, source). Every default-project file "incurs a non-trivial performance overhead"; `maximumDefaultProjectFileMatchCount_THIS_WILL_SLOW_DOWN_LINTING` defaults to 8 ([parser](https://typescript-eslint.io/packages/parser/)).
- **Fix:** upgrade to ≥8.72.1. Replace `allowDefaultProject` with `disableTypeChecked` on `*.config.*` and scripts.
- **Gain:** 362 ± 42 ms on 1024 files, about 5% (cited, PR #12988). **Risk:** those files lose typed rules.

**L6 Single-run inference off**
- **Check:** look for `TSESTREE_SINGLE_RUN=false`, `disallowAutomaticSingleRunInference: true`, or `eslint --fix` in CI: `--fix` disables inference unless `TSESTREE_SINGLE_RUN=true` (local, source). Inference needs `CI=true`, or ESLint started from `node_modules/.bin/eslint` / `node_modules/eslint/bin/eslint.js`, so a Node-API wrapper outside CI misses it.
- **Fix:** `env: TSESTREE_SINGLE_RUN: true` on the CI lint step. **Gain:** "up to 10-20%" in CI (cited, [parser](https://typescript-eslint.io/packages/parser/)). **Risk:** do not set it for watch mode or the IDE.

**L7 `--concurrency`**
- **Check:** `grep -rn -- '--concurrency' package.json .github/workflows/`. Requires ESLint ≥9.34.0; the default is `off`.
- **Facts:** `auto` uses ceil(files/50) workers, capped at `os.availableParallelism()/2` (2 on a 4-vCPU runner). With `--cache-strategy content`, `auto` counts every file, cached or not (local, 10.14.0 source). For typed linting there is "considerable additional overhead because each thread needs to load the TypeScript project" ([RFC](https://github.com/eslint/rfcs/blob/main/designs/2024-multithread-linting/README.md)), so memory grows with the worker count.
- **Fix:** benchmark `off`, 2 and 4 on the CI runner label; untyped configs benefit most. ESLint 9.37 fixed `auto` + `--cache` being slower ([v9.37](https://eslint.org/blog/2025/10/eslint-v9.37.0-released/)).
- **Gain:** about 1.30× "as a starting point", up to 3.01× (cited, [blog](https://eslint.org/blog/2025/08/multithread-linting)). **Risk:** CI runners "may throttle resources or use virtualized CPU cores", and typed linting can hit OOM.

**L8 Slow plugins and rules**
- **Check:** in the TIMING table, look at `prettier/prettier`, `import/*`, `@stylistic/indent`.
- **Fix, `eslint-plugin-prettier`:** "each file will be parsed twice"; run `prettier --check --cache` as its own step instead. **`@stylistic/indent`:** "a _lot_ of computations across every single token"; use a formatter instead. **Import plugin:** turn off `import/named`, `namespace`, `default`, `no-named-as-default-member` and `no-unresolved`, which TS covers. `no-named-as-default`, `no-cycle`, `no-unused-modules` and `no-deprecated` belong in CI only, not in the editor. For `import/extensions`, use TS `node16`/`nodenext` instead of the disk lookups ([perf](https://typescript-eslint.io/troubleshooting/typed-linting/performance/)). `import/no-cycle` is "comparatively computationally expensive"; it has `maxDepth`, `ignoreExternal` and `disableScc` ([no-cycle](https://github.com/import-js/eslint-plugin-import/blob/main/docs/rules/no-cycle.md)). eslint-plugin-import-x claims to be faster (Rust `unrs-resolver`, `get-tsconfig`) (vendor, unmeasured).
- **Gain:** the rule's share of the TIMING output. **Risk:** with no-cycle limited by depth or removed, cycles go uncaught.

**L9 Oxlint pre-pass**
- **Check:** `grep -n oxlint package.json`, and whether ESLint still runs rules that Oxlint covers.
- **Fix:** run `oxlint` first (fail fast). Then put `...oxlint.configs['flat/recommended']`, `...oxlint.buildFromOxlintConfigFile('./.oxlintrc.json')` or `...(await oxlint.buildFromConfigFile('./oxlint.config.ts'))` **last** in `eslint.config.*` ([eslint-plugin-oxlint](https://www.npmjs.com/package/eslint-plugin-oxlint)). Migrate the config with `@oxlint/migrate` ([Oxlint](https://oxc.rs/docs/guide/usage/linter.html)).
- **Gain:** "50 to 100 times faster than ESLint" (vendor) for the rules it takes over. ESLint only saves those rules' TIMING share, because parsing and the TS program stay.
- **Risk:** rule semantics can differ, and JS plugins are "alpha".

**L10 Oxlint type-aware instead of typed ESLint**
- **Fix:** `oxlint --type-aware` with `oxlint-tsgolint@7`; config `options.typeAware` (root-only). It covers 59 of typescript-eslint's 61 typed rules. `--type-check` adds tsc diagnostics from the same program ([oxc blog](https://oxc.rs/blog/2026-07-22-type-aware-linting-stable)).
- **Gain:** "12 to 18 times faster" (vendor, M4 Pro; vscode 83.2 s → 6.96 s).
- **Risk:** it is built on TS 7.0.2, so the tsconfig must work on TS 7, and 2 rules are missing. If `--type-check` replaces a `tsc` job, say so (ground rule: never drop a check silently).

**L11 Biome cost drivers**
- **Check:** enabled rules from the `project` domain (`noImportCycles`, `noUnresolvedImports`, …) or the `types` domain (`noFloatingPromises`, …). "Biome will scan the entire project" and "The scanning phase will have a performance impact" ([domains](https://biomejs.dev/linter/domains/)).
- **Fix:** force-ignore build output so it is never indexed: `"files": {"includes": ["**", "!!**/dist"]}` (≥2.3.0) ([config](https://biomejs.dev/reference/configuration/)). Use `biome ci` in CI; `--threads`/`BIOME_THREADS` caps threads on small runners.
- **Gain:** unmeasured. The formatter is "~35x" faster than Prettier (vendor: 2,104 files, i7-1270P) ([biomejs.dev](https://biomejs.dev/)). **Risk:** a plain `!` ignore still lets the scanner index files that are imported.

**L12 Changed-files lint on PRs**
- **ESLint:** `git diff -z --name-only --diff-filter=ACMR "origin/$GITHUB_BASE_REF...HEAD" -- '*.[jt]s' '*.[jt]sx' | xargs -0 npx eslint --pass-on-no-patterns --no-warn-ignored --max-warnings 0`. GNU xargs (the Ubuntu runners) still runs the command once on empty input, and `eslint` with no patterns lints `.`; `--pass-on-no-patterns` exits 0 instead. A passed file that is ignored warns and fails `--max-warnings 0` unless you add `--no-warn-ignored` (local, 10.14.0). A long list makes xargs split into several runs, and each run builds the TS program again.
- **Biome:** `biome ci --changed --since=origin/$GITHUB_BASE_REF --no-errors-on-unmatched`. It needs `vcs.enabled`, `vcs.clientKind: "git"`, and either `vcs.defaultBranch` or `--since` ([VCS](https://biomejs.dev/guides/integrate-in-vcs/)). Add `--reporter=github` for annotations; 2.6.6 picks that reporter automatically when `GITHUB_ACTIONS=true`, as does Oxlint 1.93.0 with its `github` format (local). Without the flag, an empty diff exits 1 with "The list is empty". Changing `biome.json` re-checks only `biome.json` (local, 2.6.6). The docs say it "doesn't check downstream importers". **Oxlint:** pass the file list with `xargs -0 -r` (with no paths it lints cwd, local) and `--no-error-on-unmatched-pattern`.
- **Preconditions:** base history (`fetch-depth: 0`, or fetch the base ref). Do a full run when `eslint.config.*`, `biome.json`, `.oxlintrc.json`, tsconfig, `package.json` or the lockfile changes.
- **Gain:** proportional to the files skipped. With typed rules the whole program is still built, so savings shrink (heuristic). **Risk:** cross-file and typed rules miss errors in untouched files, so keep a full lint on `main` and `merge_group`.

## Cache paths

| Tool | Path | Key inputs | Restore order / notes |
|---|---|---|---|
| ESLint `--cache` | `--cache-location .cache/eslint/`. A path with a trailing `/` (or an existing dir) becomes `<dir>/.cache_<hash(cwd)>`; a file path is used as-is. Default: `.eslintcache` in cwd. | `eslint-${{ runner.os }}-${{ hashFiles('<lockfile>','eslint.config.*') }}-${{ github.sha }}` + restore-keys on the prefix without the sha | Outside `node_modules`, so independent of install order. Entries are keyed by **absolute file path**: a different checkout dir or cwd gives 0 hits (local). On GitHub-hosted runners the path is stable; container jobs (`/__w/…`) and host jobs don't share. Built-in invalidation hashes ESLint version + Node version + the serialized config for each file; plugins count as `name@meta.version`, so a plugin without `meta.version` doesn't invalidate. Hence the lockfile in the key (local, source). Files that `--fix` changed are not cached. |
| Prettier `--cache` | Default `node_modules/.cache/prettier/.prettier-cache`, which `npm ci` wipes. Move it with `--cache-location .cache/prettier/.prettier-cache` | lockfile + `.prettierrc*` + sha | Keys: Prettier version, options, Node version, content (the default strategy). "Plugins version and implementation are not used as cache keys", so put the lockfile in the key. Running without `--cache` deletes the cache ([CLI](https://prettier.io/docs/cli)). |
| typescript-eslint | none on disk. `cacheLifetime` is in-process (30 s default) | — | Every CI run pays for the program build. |
| Oxlint / Biome | no result cache (no cache flag in 1.93.0 / 2.6.6 `--help`, local) | — | Biome's platform cache dir holds daemon logs only; don't cache it. |
| Turbo/Nx lint task | see `turbo.md` / `nx.md` | — | Task-level replay, which skips the run entirely. |

```yaml
- uses: actions/cache@v6
  with:
    path: .cache/eslint
    key: eslint-${{ runner.os }}-${{ hashFiles('package-lock.json', 'eslint.config.*') }}-${{ github.sha }}
    restore-keys: eslint-${{ runner.os }}-${{ hashFiles('package-lock.json', 'eslint.config.*') }}-
- run: npx eslint . --cache --cache-strategy content --cache-location .cache/eslint/
```

## Version traps

- **ESLint 9.0.0** (2024-04-05): flat config by default; `--stats` added. **9.34.0** (2025-08-22): `--concurrency` added, default `off`. **9.37.0**: the `auto`-worker heuristic improved for cached runs.
- **ESLint 10.0.0** (2026-02-06): eslintrc is gone. `.eslintrc*`, `.eslintignore`, `ESLINT_USE_FLAT_CONFIG`, `--no-eslintrc`, `--env`, `--rulesdir`, `--ignore-path` and `--resolve-plugins-relative-to` were removed, and `/* eslint-env */` is now an error. Config lookup starts from **each linted file's directory**, so nested `eslint.config.*` files now apply. Node `^20.19.0 || ^22.13.0 || >=24` ([v10](https://eslint.org/blog/2026/02/eslint-v10.0.0-released/)). `--cache-strategy` still defaults to `metadata` in 10.14.0.
- **typescript-eslint:** `EXPERIMENTAL_useProjectService` (v6/v7) became `projectService` (v8.0). **8.72.1**: one Program per tsconfig for the project service in single-run mode. The peer range `typescript <6.1.0` means typed ESLint cannot run on TS 7, which has no API. Keep `typescript` resolving to 6.x for lint (an npm alias to `@typescript/typescript6` is a common pattern), or move typed rules to tsgolint (L10, `typescript.md`). `jsDocParsingMode` defaults to `'all'` with `project` and to `'none'` otherwise; `'none'` speeds up parsing unless a rule reads JSDoc tags.
- **Oxlint:** `oxlint-tsgolint` went from 0.x (alpha, last 0.25.0, 2026-07-16) to `7.0.2000` (2026-07-21). The version encodes the TS release (7.0.2) plus a patch number. Config files: `.oxlintrc.json(c)`, `oxlint.config.ts/.mts`. `eslint-plugin-oxlint` 1.93 exports both `buildFromOxlintConfigFile` (sync) and `buildFromConfigFile` (async, which is what the README shows).
- **Biome 2.0.0** (2025-06-17): `files.include`/`ignore` became `files.includes` (`biome migrate --write`). It added the scanner and project rules; the scanner indexed `node_modules` by default. **2.2.0**: files that `files.includes` ignores are no longer indexed unless imported. **2.3.0** (2025-10-24): `!!` force-ignore; `files.experimentalScannerIgnores` deprecated. **2.4.0** (2026-02-15): `--profile-rules`.

## Sources

- https://eslint.org/docs/latest/use/command-line-interface · https://eslint.org/docs/latest/extend/custom-rules · https://eslint.org/docs/latest/extend/stats
- https://eslint.org/blog/2025/08/multithread-linting · https://eslint.org/blog/2025/10/eslint-v9.37.0-released/ · https://eslint.org/blog/2026/02/eslint-v10.0.0-released/
- https://github.com/eslint/rfcs/blob/main/designs/2024-multithread-linting/README.md · https://github.com/eslint/eslint/blob/main/CHANGELOG.md
- https://typescript-eslint.io/troubleshooting/typed-linting/performance/ · https://typescript-eslint.io/troubleshooting/faqs/eslint · https://typescript-eslint.io/packages/parser/
- https://typescript-eslint.io/users/configs/ · https://typescript-eslint.io/blog/project-service · https://typescript-eslint.io/getting-started/typed-linting
- https://github.com/typescript-eslint/typescript-eslint/pull/12988 · https://github.com/typescript-eslint/typescript-eslint/releases/tag/v8.72.1
- https://github.com/import-js/eslint-plugin-import/blob/main/docs/rules/no-cycle.md · https://www.npmjs.com/package/eslint-plugin-import-x
- https://oxc.rs/docs/guide/usage/linter.html · https://oxc.rs/docs/guide/usage/linter/cli.html · https://oxc.rs/blog/2026-07-22-type-aware-linting-stable · https://www.npmjs.com/package/eslint-plugin-oxlint
- https://biomejs.dev/reference/cli/ · https://biomejs.dev/reference/configuration/ · https://biomejs.dev/linter/domains/ · https://biomejs.dev/guides/integrate-in-vcs/ · https://biomejs.dev/internals/architecture/ · https://biomejs.dev/
- https://github.com/biomejs/biome/releases (tags @biomejs/biome@2.0.0, 2.2.0, 2.3.0, 2.4.0)
- https://prettier.io/docs/cli
