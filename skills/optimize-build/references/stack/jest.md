# jest — optimize-build stack reference

Use when: detect-stack.sh reported `jest`. Lanes: test, cache.

Checked 2026-11-09 and re-verified 2026-11-18 against Jest **30.5.2** (latest, 2026-09-18), its source at tag `v30.5.2`, docs and changelogs. **(local)** = run on 2026-11-09 with Jest 30.5.2 on Node 26.13 (Apple Silicon): it proves behaviour, not CI gains. Read versions first: `npm ls jest jest-environment-jsdom jsdom babel-jest ts-jest @swc/jest typescript`. Generic worker, blocker, shuffle and shard guidance is in `test-parallelism.md`. DOM, CSS and import cost in general is in `test-environment.md`.

## Measure

- **Agent trap (30.3.0+).** When an AI-agent env var is set (`CLAUDECODE`, `AI_AGENT`, `CODEX_SANDBOX`, `CURSOR_AGENT`, `GEMINI_CLI`, …), Jest swaps the default reporter for a terse `agent` reporter: no `PASS` lines, no per-file times ([3f17932](https://github.com/jestjs/jest/commit/3f17932061c0203999451e5852664093de876709)). When you run Jest yourself, always pass `--reporters=default` (local).
- **Resolved config.** `npx jest --showConfig` prints JSON. Each entry in `.configs[]` has `cacheDirectory`, `testEnvironment`, `transform` and `id`, and `.globalConfig.maxWorkers` is the resolved worker count. Count files with `npx jest --listTests | wc -l`.
- **CI log, no repo change.** The default reporter adds `(N s[, M MB heap size])` to a `PASS|FAIL <file>` line only when the file's runtime exceeds `slowTestThreshold` (default 5 s). Heap size appears with `--logHeapUsage`. The run ends with `Time:`. On GitHub the log is coloured (verified pipeline, local):
  ```bash
  gh run view $RUN --log | sed 's/\x1b\[[0-9;]*m//g' \
    | sed -nE 's/.*(PASS|FAIL) +([^ ]+) \(([0-9.]+) s[,)].*/\3\t\2/p' | sort -rn | head -25
  ```
- **Per-file wall time.** Run `npx jest --ci --json --outputFile=jest.json`. `testResults[].startTime/endTime` are `perfStats.start/end`, and `start` is taken **after** the test environment has loaded ([runTest.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-runner/src/runTest.ts)), so env cost does not appear. Use the jq in `test-parallelism.md` §1.3 for ranking and average concurrency.
- **Per-file phases.** This reporter was verified (local). `perfStats` gained its setup fields in 30.0 ([#14622](https://github.com/jestjs/jest/pull/14622)):
  ```js
  // slow-files.cjs. runtime = setupFiles + setupFilesAfterEnv + tests; env is extra
  module.exports = class { constructor() { this.rows = [] }
    onTestResult(_t, r) { const p = r.perfStats; this.rows.push({ file: r.testFilePath.slice(-60),
      env: p.loadTestEnvironmentEnd - p.loadTestEnvironmentStart, setupFiles: p.setupFilesEnd - p.setupFilesStart,
      afterEnv: (p.setupAfterEnvEnd ?? 0) - (p.setupAfterEnvStart ?? 0), runtime: p.runtime }) }
    onRunComplete() { console.table(this.rows.sort((a, b) => b.env + b.runtime - a.env - a.runtime).slice(0, 15)) } }
  ```
  Run `npx jest <paths> --reporters=default --reporters=./slow-files.cjs`. Put test paths **before** `--reporters`. It is an array flag and swallows later positional arguments ("Could not resolve a module for a custom reporter", local).
- **Transform and crawl cost.** Run `npx jest --clearCache; time npx jest --ci; time npx jest --ci`. Cold minus warm is what CI pays on every run when the cache is not persisted.
- **Memory.** `--logHeapUsage` prints heap per file. For leak hunting, add `--runInBand` and `node --expose-gc` ([CLI](https://jestjs.io/docs/cli#--logheapusage)). For CPU share, use `/usr/bin/time -v` (`test-parallelism.md` §1.3).

## Checks

**1. Whole-suite serialisation.**
- **Check:** `rg -n --hidden -g '!node_modules' -g package.json -g 'jest.config.*' -g '*.y*ml' -e '--runInBand' -e '\bjest\b.*\s-i\b' -e '--detectOpenHandles' -e '(-w|--maxWorkers)[= ]1\b' -e 'maxWorkers["'\'']?\s*:\s*["'\'']?1\b' .` (tested, local). Then find out why with `git log -S'--runInBand' --oneline`.
- **Good:** no hits on runners with ≥3 vCPU, or a documented shared resource confined to its own invocation.
- **Fix:** remove the flag and give each worker its own DB or port, keyed on `JEST_WORKER_ID` (1..maxWorkers; `1` for every test in band, per [env vars](https://jestjs.io/docs/environment-variables)). `maxWorkers` is root-only, and since 30.5.1 it only warns in a project config. A serial lane is therefore a second invocation: `jest --selectProjects unit && jest --selectProjects db --runInBand`.
- **Gate:** run `jest --ci --randomize --seed=$RANDOM` (≥29.5) several times. It shuffles tests and `describe`s **within** each file only ([jest-circus run.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-circus/src/run.ts)). To shuffle file order, write a custom `testSequencer.sort()`.
- **Gain:** `--runInBand` runs every file serially in the main process and is meant for debugging ([CLI](https://jestjs.io/docs/cli#--runinband)). Removing it gains at most ≈ workers× on a CPU-bound step (arithmetic). **It is 0 on 2 vCPU**, where the default is already 1 worker, which runs in band.
- **Risk:** collisions on shared state. `--detectOpenHandles` implies `--runInBand` and "has a significant performance penalty" ([CLI](https://jestjs.io/docs/cli#--detectopenhandles)), so never ship it to CI. The Troubleshooting page's "up to 50%" from `--runInBand` on CI rests on 2016 findings ([#1524](https://github.com/jestjs/jest/issues/1524#issuecomment-262366820)) from before 29.4 counted CPUs with `os.availableParallelism()`. Measure both ways.

**2. Worker count.**
- **Check:** compare `npx jest --showConfig | jq .globalConfig.maxWorkers` with `node -p 'require("os").availableParallelism()'`, run in a one-off CI step.
- **Good:** `maxWorkers` unset, or equal to the container's CPU quota. The default is `max(n−1, 1)`, and `max(⌊n/2⌋, 1)` in watch mode ([getMaxWorkers.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/getMaxWorkers.ts)).
- **Fix:** pass an explicit integer equal to the quota when Node is older than 22.12, which has no cgroup awareness (`test-parallelism.md` §1.1). Jest treats only 1–100% as a percentage, so **`"200%"` means 200 workers**. `test.concurrent` is capped by `maxConcurrency` (default 5) and helps only I/O-bound tests. `workerThreads: true` is experimental: messages use structured clone, and the gain is unmeasured.
- **Auto in-band:** Jest runs in band by itself when `maxWorkers ≤ 1`, when there is ≤1 test file, or when there are ≤20 files whose cached timings are all <1 s. Watch mode or any `workerIdleMemoryLimit` disables this ([testSchedulerHelper.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-core/src/testSchedulerHelper.ts)).
- **Gain:** no oversubscription timeouts or OOMs. Typical, unmeasured. **Risk:** none.

**3. Memory.**
- **Check:** look for `heap out of memory`, exit 137, "A worker process has failed to exit gracefully", or `--logHeapUsage` growing file after file.
- **Fix:** set `workerIdleMemoryLimit: '1GiB'` in the **root** config (≥29.0; works with 1 worker or `--runInBand` from 29.4.3; `0` restarts after every file since 30.0.5). Use units. Values ≤1 or `%` are fractions of `os.totalmem()`, which "does not work on Linux CircleCI" ([config](https://jestjs.io/docs/configuration#workeridlememorylimit-numberstring)). With no `JEST-01` warnings, also set `testEnvironmentOptions: { globalsCleanup: 'on' }` (30.0+, default `'soft'`).
- **Gain:** the blog promises "major memory savings" for `globalsCleanup: 'on'` but gives no figure. **Risk:** each recycle pays env and setup again, and a limit turns off auto in-band.

**4. Sharding** (only after one job's cores are saturated, per `test-parallelism.md` §7).
- **Check:** `rg -n -e '--shard' .github/workflows`, plus per-shard step times.
- **Good:** max/mean shard time ≤ ~1.3 (heuristic).
- **Fix:** use `jest --ci --shard=${{ matrix.shard }}/${{ strategy.job-total }}` (≥28.0). The default `shard()` sorts files by a path hash and cuts equal **counts**, ignoring durations ([test-sequencer](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-test-sequencer/src/index.ts)). For balance, write a custom `testSequencer` whose `shard()` (runs before `sort()`, may return a Promise) packs longest-first from a previous `--json`. Jest has no report merge, so merge the JSON, JUnit and coverage files yourself.
- **Gain:** ≤N× on the test step, minus N × setup. **Risk:** imbalance, and each job is billed separately.

**5. Environment scope.**
- **Check:** `rg -n -g '!node_modules' -g package.json -g 'jest.config.*' -e 'testEnvironment|setupFilesAfterEnv' .` and `git grep -l '@jest-environment' | wc -l`.
- **Good:** the root `testEnvironment` is `node` (the default since 27.0). DOM files opt in with `/** @jest-environment jsdom */`, and DOM-only setup (jest-dom, RTL, MSW) does not load for node files.
- **Fix:** switch the root to `node` and add docblocks, or use `projects: [{displayName: 'dom', testEnvironment: 'jsdom', testMatch, setupFilesAfterEnv}, …]`.
- **Gain (smaller than in Vitest):** jsdom is `require`d once per worker, and each file gets a `new JSDOM(…, {pretendToBeVisual: true, runScripts: 'dangerously'})` ([abstract env](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-environment-jsdom-abstract/src/index.ts)). Locally, env load was 105–181 ms for a worker's first jsdom file, then a median of 3–5 ms; `node` had a median of 1 ms. `new JSDOM` itself took 90 ms on the first file and 2–3 ms after that. The real win is DOM setup: `setupFiles` and `setupFilesAfterEnv` run "once per test file" ([config](https://jestjs.io/docs/configuration#setupfiles-array)). The reporter's `afterEnv` column shows it.
- **Risk:** each project builds its own haste map, and the config string is part of the transform key ([ScriptTransformer.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-transform/src/ScriptTransformer.ts)), so files are transformed once per project. Prefer docblocks. Files that touch `window` indirectly fail under `node`.

**6. jsdom version.**
- **Check:** `npm ls jsdom jest-environment-jsdom`. Style-heavy suites are the ones at risk: CSS-in-JS combined with `ByRole`, `toBeVisible` or user-event.
- **Bundled jsdom** (npm metadata): Jest 30 `^26.1.0`, 29.x `^20`, 28.x `^19`.
- **Fix:** a custom env on your own jsdom (≥30.0; the abstract package's peer is `jsdom: *`, and 30.2.0 added jsdom 27). Locally, 30.5.2 ran with jsdom 31.0.0:
  ```js
  // jest-env-jsdom.cjs → testEnvironment: '<rootDir>/jest-env-jsdom.cjs'
  const B = require('@jest/environment-jsdom-abstract').default
  module.exports = class extends B { constructor(c, x) { super(c, x, require('jsdom')) } }
  ```
  MSW under jsdom needs `testEnvironment: 'jest-fixed-jsdom'`, because jsdom replaces `Request`, `Response` and `TextEncoder` ([MSW FAQ](https://mswjs.io/docs/faq)).
- **Gain:** style-heavy queries only. `getAllByRole` with 5k rules ran ~22–28× faster on jsdom 31 than on 26 (local, `test-environment.md` §3). Per-file env cost is unchanged.
- **Risk:** jsdom 31 needs Node `^22.22.2 || ^24.15.0 || >=26` and moved canvas to `@napi-rs/canvas`. The jsdom 21→26 move broke `window.location` mocks ([Jest 30](https://jestjs.io/blog/2025/06/04/jest-30)). `@happy-dom/jest-environment` 21.0.4 exists, but Jest already pays env load once per worker, and happy-dom was 2–2.3× slower than jsdom 31 on style-heavy ByRole (`test-environment.md` §3).

**7. CSS and assets.**
- **Check:** `rg -n -g '!node_modules' -g package.json -g 'jest.config.*' -e 'moduleNameMapper|identity-obj-proxy|\.(css|less|s[ac]ss)' .`. Look for CSS transformers (postcss, sass) in `transform`, and for `toHaveStyle`/`getComputedStyle` in tests.
- **Good:** styles are mapped to a stub, and no CSS reaches the document unless a test asserts on it.
- **Fix:** `moduleNameMapper: {'\\.(css|less)$': 'identity-obj-proxy'}` for CSS Modules, or `<rootDir>/__mocks__/styleMock.js`. Extend the regex to `scss|sass` as needed, and map images and fonts to `fileMock.js` ([webpack guide](https://jestjs.io/docs/webpack)).
- **Gain:** no CSS transform, and fewer rules for every `getComputedStyle` call (`test-environment.md` §3).
- **Risk:** style assertions break, and runtime CSS-in-JS injects `<style>` regardless.

**8. Transformer.** Inspect it with `npx jest --showConfig | jq '.configs[].transform'`. ts-jest type-checks unless `isolatedModules` is set in tsconfig: `grep -n isolatedModules tsconfig*.json`.

| Transformer | Type-checks? | Notes |
|---|---|---|
| `babel-jest` (default `{"\\.[jt]sx?$": "babel-jest"}`) | no | Cost depends on the preset; use `targets: {node: 'current'}`. Injects the `jest.mock` hoisting plugin |
| `@swc/jest` 0.2.39 | no | `transform: {'^.+\\.[tj]sx?$': '@swc/jest'}` (the docs write `(t\|j)`). Reads `.swcrc` from `process.cwd()`, not `rootDir` (a monorepo trap). Hoists `jest.mock` (`jsc.transform.hidden.jest`). Coverage goes through Jest's istanbul unless `experimental.customCoverageInstrumentation` is set ([source](https://github.com/swc-project/pkgs/blob/main/packages/jest/index.ts)) |
| `ts-jest` 29.4.15 | **yes**, unless tsconfig has `isolatedModules: true` | "Using `isolatedModules: false` comes with a cost of performance". The ts-jest `isolatedModules` option has been deprecated since 29.3 in favour of tsconfig ([docs](https://kulshekhar.github.io/ts-jest/docs/getting-started/options/isolatedModules)). Restrict the pattern to `^.+\\.ts$` and set `allowJs: false` ([troubleshooting](https://github.com/kulshekhar/ts-jest/blob/main/website/docs/guides/troubleshooting.md)) |
| `esbuild-jest` | no | Last release 0.5.0 on 2021-02-22. Avoid it |

- **Good:** a transpile-only transformer, with types checked by a separate `tsc --noEmit` job. `transformIgnorePatterns` (default `["/node_modules/", "\\.pnp\\.[^\\\/]+$"]`) un-ignores only the packages that need it, since each one gets transformed.
- **Gain:** typical, unmeasured; swc publishes no figure. "A transformer only runs once per file unless the file has changed" ([config](https://jestjs.io/docs/configuration#transform-objectstring-pathtotransformer--pathtotransformer-object)), so with a persisted cache the choice matters only for changed files. Measure cold and warm first.
- **Risk:** swc drops babel-only plugins (macros, styled-components). ts-jest's peer range is `typescript >=4.3 <7`. TS 7 needs ts-jest ≥29.4.12 with `typescript` aliased to `@typescript/typescript6` ([#5386](https://github.com/kulshekhar/ts-jest/pull/5386)).

**9. Node type stripping (≥30.5.2).**
- **Check:** a `.ts` suite with no `.tsx`, `enum`, `namespace` or parameter properties, on Node `^22.13.0 || >=23.2.0`.
- **Fix:** set `transform: {}`, or patterns that don't claim `.ts/.mts/.cts`. Jest then calls `module.stripTypeScriptTypes()` ([#16421](https://github.com/jestjs/jest/pull/16421)). Locally this ran on Node 26.13.
- **Gain:** no transformer at all. Unmeasured.
- **Risk:** `jest.mock()` is no longer hoisted, so move it above the imports or use `jest.unstable_mockModule`. The unsupported syntax throws. Node's version becomes part of the cache key.

**10. Barrel imports.**
- **Check:** the barrel grep in `test-environment.md` §4.
- **Fix:** `babel-jest-boost`, `babel-plugin-transform-barrels` or `no-barrel-file`.
- **Gain:** "up to 100x" ([Jest 30](https://jestjs.io/blog/2025/06/04/jest-30)). Treat it as an upper bound.
- **Risk:** these are Babel plugins, so they don't help under swc or ts-jest. Barrels with side effects can break.

**11. Coverage.**
- **Check:** the CI test step has `--coverage` or `collectCoverage: true`, and `coverageProvider` is unset (default `babel`).
- **Fix:** set `coverageProvider: 'v8'`, or collect coverage in one job only.
- **Gain:** babel-plugin-istanbul is "quite slow and memory-intensive, especially for large files and code bases" ([Jest 25](https://jestjs.io/blog/2020/01/21/jest-25)). The size of the gain is unmeasured.
- **Risk:** coverage numbers and ignore-comment syntax differ, so thresholds may fail.

**12. Upgrade.**
- **Check:** `npx jest --version` is below 30.5.
- **Gain** ([Jest 30](https://jestjs.io/blog/2025/06/04/jest-30)): on one app, server tests went from ~1350 s / 7.8 GB to ~850 s / 1.8 GB and client tests from ~49 s to ~44 s (credited to unrs-resolver). Happo went from 14 to 9 min, which also included open-handle cleanup. In 30.5.0 the warm default resolver became ~3× cheaper, 6900 → 2044 ns per resolution ([#16373](https://github.com/jestjs/jest/pull/16373)). `jest-snapshot` stopped loading ~200 modules per test process, and per-require overhead dropped.
- **Risk:** see Version traps.

## Cache paths

- **Path:** `cacheDirectory` (`cache: true` by default). The docs say `"/tmp/<path>"`. The code uses `realpath(os.tmpdir())/jest_<uid in base36>` ([getCacheDirectory.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/getCacheDirectory.ts)), which is outside the workspace, so on hosted runners **nothing persists** by default. Read the real path with `npx jest --showConfig | grep cacheDirectory`. `--no-cache` "makes Jest at least two times slower" ([CLI](https://jestjs.io/docs/cli#--cache)). That figure is an upper bound for a cold cache, which still transforms each file only once. Persisting the cache pays off mainly with expensive transforms (babel, ts-jest).
- **Set it absolute:** `--cacheDirectory="$GITHUB_WORKSPACE/.jest-cache"`, and gitignore it. CLI options apply to every project, and a relative path resolves against each project's `rootDir` ([normalize.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/normalize.ts)).
- **Contents:** each name carries the project config `id` = sha1(`rootDir`, config path, project index).
  - `jest-transform-cache-<id>-<hash incl. Jest version>/` is the main win. It is content-addressed: file content, config string, the `instrument` flag and the transformer key. babel-jest's key adds its options, `NODE_ENV`, `BABEL_ENV` and `process.version` ([babel-jest](https://github.com/jestjs/jest/blob/v30.5.2/packages/babel-jest/src/index.ts)).
  - `haste-map-<id>-…` reuses an entry only if the file's mtime is unchanged ([crawlers/node.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-haste-map/src/crawlers/node.ts)). A fresh clone resets mtimes, so it rebuilds anyway. It is harmless to keep.
  - `perf-cache-<id>` holds last durations and failures. It drives failed-first, then longest-first ordering (with no cache, files are ordered by size) and the ≤20-fast-files auto in-band rule.
- **Key:** `jest-${{ runner.os }}-${{ runner.arch }}-node<version>-${{ hashFiles('<lockfile>', '**/jest.config.*', '**/babel.config.*', '**/.swcrc') }}-${{ github.sha }}`. The restore-key is the same string up to and including the hash. **Don't fall back past the lockfile hash.** babel-jest's key covers Babel *options*, not plugin versions (inferred from source), so a plugin bump could serve stale output. `jest --clearCache` wipes the directory.
- **Order:** restore any time before the test step. It is independent of `npm ci` unless `cacheDirectory` sits under `node_modules`, in which case restore **after** install. Save only from the default branch (`ci-github-caching.md` fix A), using the same command CI runs. Coverage and non-coverage transforms are separate entries.
- **Misses and growth:** the absolute checkout path is part of `id`, so container jobs (`/__w/…`) and host jobs never share. A Jest upgrade starts a new transform directory, and 30.5.0 also re-keyed custom transformers built on `@jest/create-cache-key-function`. Jest never prunes, so the archive grows until the key rolls. Watch its size with `gh cache list --key jest-`.

## Version traps

| Version | Change → trap |
|---|---|
| 27.0 | Default `testEnvironment` jsdom → `node`, and default runner `jest-circus`. Repos that upgraded often pinned `testEnvironment: 'jsdom'` for everything (check 5) |
| 28.0 | `jest-environment-jsdom` no longer ships with Jest; install the same major. `--shard` added. `testURL` → `testEnvironmentOptions.url`, `extraGlobals` → `sandboxInjectedGlobals`, `timers` → `fakeTimers` |
| 29.0 / 29.4 / 29.5 | 29.0: `workerIdleMemoryLimit`. 29.4: worker count from `os.availableParallelism()`. 29.4.3: the memory limit works in band. 29.5: `--randomize` (`--seed` exists since 29.2) |
| 30.0 (2025-06-10) | Node 14/16/19/21/23 dropped (engines `^18.14.0 \|\| ^20 \|\| ^22 \|\| >=24`). TS ≥5.4. jsdom 26. `--testPathPattern` → `--testPathPatterns`. `--init` removed. Resolver moved to `unrs-resolver`. `globalsCleanup` (default `'soft'`). `.mts`/`.cts` added to default extensions and `testMatch`. Waiting for unhandled rejections "can slightly slow down test completion" (`waitForUnhandledRejections`) ([upgrade guide](https://jestjs.io/docs/upgrading-to-jest30)) |
| 30.0.5 / 30.2.0 | 30.0.5: `workerIdleMemoryLimit: 0`. 30.2.0: the abstract jsdom env supports jsdom 27 |
| 30.3.0 | Agent reporter: hides per-file lines when an agent env var is set (see Measure) |
| 30.4.0 | `workerGracefulExitTimeout` (default 500 ms), `--collectTests`, sync ESM evaluation on Node ≥24.9 |
| 30.5.0 / 30.5.1 | 30.5.0: resolver and runtime speedups, cache keys re-shaped. 30.5.1: `maxWorkers`/`coverageThreshold` in a project config warn; `workerIdleMemoryLimit`, `reporters` and `workerThreads` are root-only ([config](https://jestjs.io/docs/configuration)) |
| 30.5.2 | Node type stripping for unclaimed `.ts/.mts/.cts` (check 9) |
| ts-jest 29.3–29.4.4 | 29.3.0 deprecated the `isolatedModules` transform option. 29.4.3 added `transpilation` and 29.4.4 reverted it, so don't use it |

## Sources

- Jest source at `v30.5.2`: [getMaxWorkers.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/getMaxWorkers.ts), [testSchedulerHelper.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-core/src/testSchedulerHelper.ts), [getCacheDirectory.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/getCacheDirectory.ts), [Defaults.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/Defaults.ts), [normalize.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/normalize.ts), [ScriptTransformer.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-transform/src/ScriptTransformer.ts), [babel-jest](https://github.com/jestjs/jest/blob/v30.5.2/packages/babel-jest/src/index.ts), [haste-map crawler](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-haste-map/src/crawlers/node.ts), [test-sequencer](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-test-sequencer/src/index.ts), [runTest.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-runner/src/runTest.ts), [jest-circus run.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-circus/src/run.ts)
- Changelogs: [CHANGELOG.md](https://github.com/jestjs/jest/blob/v30.5.2/CHANGELOG.md), [CHANGELOG_PRE_v30.md](https://github.com/jestjs/jest/blob/v30.5.2/CHANGELOG_PRE_v30.md), [#16421](https://github.com/jestjs/jest/pull/16421), [#16373](https://github.com/jestjs/jest/pull/16373), [3f17932](https://github.com/jestjs/jest/commit/3f17932061c0203999451e5852664093de876709)
- Docs: [CLI](https://jestjs.io/docs/cli), [configuration](https://jestjs.io/docs/configuration), [webpack](https://jestjs.io/docs/webpack), [troubleshooting](https://jestjs.io/docs/troubleshooting), [getting started (TS)](https://jestjs.io/docs/getting-started), [env vars](https://jestjs.io/docs/environment-variables), [upgrading to 30](https://jestjs.io/docs/upgrading-to-jest30)
- Blogs: [Jest 30](https://jestjs.io/blog/2025/06/04/jest-30), [Jest 25](https://jestjs.io/blog/2020/01/21/jest-25)
- Transformers and environments: [swc jest](https://swc.rs/docs/usage/jest), [@swc/jest source](https://github.com/swc-project/pkgs/blob/main/packages/jest/index.ts), [ts-jest isolatedModules](https://kulshekhar.github.io/ts-jest/docs/getting-started/options/isolatedModules), [ts-jest CHANGELOG](https://github.com/kulshekhar/ts-jest/blob/main/CHANGELOG.md), [ts-jest #5386](https://github.com/kulshekhar/ts-jest/pull/5386), [MSW FAQ](https://mswjs.io/docs/faq)
- npm metadata, 2026-11-09: `npm view jest-environment-jsdom@{30.5.2,29.7.0,28.1.3} dependencies.jsdom`, `npm view jsdom engines`, `npm view esbuild-jest time`
