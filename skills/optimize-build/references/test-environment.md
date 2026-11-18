# Reference: test environment and per-test cost (Vitest, Jest, Playwright)

> **Use when** a measured hotspot is a JS/TS unit, component or E2E test step and you need to know where the time goes: DOM environment, CSS, imports and transforms, setup files, or per-test helpers.
> **Skip** for worker counts and sharding (`test-parallelism.md`), for cache keys (`ci-github-caching.md`), and for non-JS runners: their per-test cost is in `stack/python.md`, `stack/go.md`, `stack/rust.md` and `stack/jvm.md`.

Facts were checked on **2026-11-09**, and each one names the version it applies to. **(cited)** means a vendor or maintainer number, linked. **(local)** means a check run on 2026-11-09 against the published package (Apple M5 Pro, Node 24.22/26.13). It is one machine, so re-measure on the repo. **(heuristic)** means typical but unmeasured. Check versions first: `npm ls vitest jest jest-environment-jsdom jsdom happy-dom @playwright/test @testing-library/dom @testing-library/user-event msw typescript`.

| Tool | Latest on 2026-11-09 | Facts that matter here |
|---|---|---|
| Vitest | 5.1.0, plus 4.1.12 (v4) and 3.2.7 (v3) | v5 needs Node ≥22.12 and Vite ≥6.4 ([migration](https://vitest.dev/guide/migration)). v4 needs Node ≥20 and Vite ≥6 ([v4 migration](https://v4.vitest.dev/guide/migration)). |
| jsdom / happy-dom | 31.0.0 (2026-11-05) / 21.0.4 | jsdom has required Node `^22.22.2 \|\| ^24.15.0 \|\| >=26` since 30.0.0. 31.0.0 adds a new CSS engine with "faster selector queries and repeated style reads" and breaks canvas by moving to `@napi-rs/canvas` ([releases](https://github.com/jsdom/jsdom/releases)). |
| DTL / user-event / MSW | 10.4.2 / 14.6.8 / 3.0.4 | MSW 3 renamed `onUnhandledRequest` to `onUnhandledFrame` and needs Node ≥22 ([3.x migration](https://mswjs.io/docs/migrations/2.x-to-3.x)). |
| ts-jest / @swc/jest / TypeScript | 29.4.15 / 0.2.39 / 7.0.2 | ts-jest's peer range is `typescript >=4.3 <7`. TS 7.0 "does not ship with an API" ([TS 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)). The `typescript@7.0.2` package only exports `./unstable/*` API entries. |

Jest's bundled jsdom and Playwright's version changes: see [stack/jest.md](stack/jest.md) check 6 and [stack/playwright.md](stack/playwright.md) Version traps.

## 1. Measure: find the dominant phase

Vitest specifics (the `Duration` line format and phases by version, reporters, import durations, `vitest doctor`, v5 hints, and the [#11807](https://github.com/vitest-dev/vitest/issues/11807) `isolate: false` inflation): see [stack/vitest.md](stack/vitest.md) Measure §1–5.

Route by the top phase: environment → §2, CSS or plugins → §3, import or transform → §4, setup or tests → §5.

- **Per-file ranking.** JSON `endTime - startTime` covers test bodies only. In Vitest 5.1, a file with about 145 ms of environment setup showed under 1 ms (local). Jest's `perfStats.start` is taken after the environment loads ([runTest.ts](https://github.com/jestjs/jest/blob/main/packages/jest-runner/src/runTest.ts)). Use a reporter instead. This one works on Vitest 3.2+ and was run on 5.1.0: `--reporter=default --reporter=./slow-files.ts`.
  ```ts
  import type { Reporter, TestModule } from 'vitest/node'
  export default class SlowFiles implements Reporter {
    rows: any[] = []
    onTestModuleEnd(m: TestModule) {
      const d = m.diagnostic()
      this.rows.push({ file: m.moduleId.slice(-60), env: d.environmentSetupDuration | 0,
        setup: d.setupDuration | 0, import: d.collectDuration | 0, tests: d.duration | 0 })
    }
    onTestRunEnd() {
      const t = (r: any) => r.env + r.setup + r.import + r.tests
      console.table(this.rows.sort((a, b) => t(b) - t(a)).slice(0, 15))
    }
  }
  ```
  For Jest, read `testResult.perfStats` in a custom reporter's `onTestResult`. Its fields are `loadTestEnvironmentStart/End`, `setupFilesStart/End`, `setupAfterEnvStart/End` and `runtime` ([types](https://github.com/jestjs/jest/blob/main/packages/jest-test-result/src/types.ts)).
- **Slow-test thresholds.** Vitest's `slowTestThreshold` is 300 ms (all majors). Jest's is 5 s ([config](https://jestjs.io/docs/configuration)).
- **CPU/heap profiles.**
  - **Workers (v4+):** set top-level `execArgv: ['--cpu-prof','--cpu-prof-dir=.prof','--heap-prof','--heap-prof-dir=.prof']` plus `fileParallelism: false`. In v3 this went under `poolOptions.<pool>.execArgv`. `--prof` does not work with `pool: 'threads'` ([profiling](https://vitest.dev/guide/profiling-test-performance)).
  - **Main thread** (Vite plugins, `globalSetup`): `node --cpu-prof ./node_modules/vitest/vitest.mjs --run`.
  - **Jest** (heap per file, `--detectOpenHandles` cost): see [stack/jest.md](stack/jest.md) Measure and check 1.

## 2. Environment: node vs happy-dom vs jsdom vs browser

| Env | Per-file cost | Use when |
|---|---|---|
| `node` (default in Vitest and Jest) | module graph only | logic, server code, hooks without DOM |
| `happy-dom` | Import costs about 90–200 ms, paid per file with the default isolating pool (cited, [perf guide](https://vitest.dev/guide/improving-performance)). It "lacks some API" ([env](https://vitest.dev/guide/environment)). | component tests without exotic DOM APIs |
| `jsdom` | Import costs about 200–500 ms, paid per file under `isolate: true` (cited, same guide). There is no layout, so `getBoundingClientRect` returns zeros. | the most spec-complete emulation |
| Jest `jsdom` | jsdom is required **once per worker**; per-file cost and measurements: see [stack/jest.md](stack/jest.md) check 5 | legacy Jest suites ([stack/jest.md](stack/jest.md) check 6 for MSW) |
| Vitest Browser Mode | "longer initialization" ([why](https://vitest.dev/guide/browser/why)), and CSS is always processed (§3) | layout, CSS, focus and canvas tests only |

Creating a window is cheap. "Creating a jsdom window takes a few milliseconds" ([#11807](https://github.com/vitest-dev/vitest/issues/11807)). The lever in Vitest is **how many times the environment module is imported**.

**Detect:**
```bash
grep -nE "environment|pool|isolate|css|setupFiles|projects|browser|deps" vitest.config.* vite.config.* 2>/dev/null
grep -nE "testEnvironment|transform|moduleNameMapper|setupFiles|cacheDirectory" jest.config.* package.json 2>/dev/null
# Candidates for the node env: test files that never touch the DOM (review by hand)
git ls-files '*.test.ts' '*.test.tsx' '*.spec.ts' '*.spec.tsx' | xargs grep -LE "render|screen\.|document|window|userEvent|fireEvent|@testing-library"
```
**Good state:** pure-logic files run in `node`. DOM files don't re-import the environment per file, or their count is small.

**Fixes:**
1. **Split node from DOM tests with `projects`.** `environmentMatchGlobs` and `poolMatchGlobs` were deprecated in 3.2 and removed in 4.0 ([v4 migration](https://v4.vitest.dev/guide/migration)). In v5, inline projects default to `extends: true`, and arrays are merged, so `setupFiles` are **appended**. Inline projects that don't change the Vite config reuse the parent's Vite server ([migration](https://vitest.dev/guide/migration)).
   ```ts
   test: { projects: [
     { extends: true, test: { name: 'unit', environment: 'node', include: ['src/**/*.test.ts'] } },
     { extends: true, test: { name: 'dom', environment: 'happy-dom', include: ['src/**/*.test.tsx'], setupFiles: ['./test/dom-setup.ts'] } },
   ] }
   ```
   To override a single file, add `// @vitest-environment node`. Vitest 5.1 also parses `@jest-environment` (dist regex `@(?:vitest|jest)-environment`). In Jest, use a `/** @jest-environment jsdom */` docblock or `projects: [{ displayName, testEnvironment, testMatch }]`.
   **Gain:** one environment import saved per moved file (90–500 ms, cited above). **Risk:** a file that touches `window` indirectly fails in `node`. Run the suite to find them.
2. **Stop recreating the environment per file** (`isolate: false` or a vm pool, with their caveats): see [stack/vitest.md](stack/vitest.md) check 6.
3. **Swap jsdom for happy-dom** where tests pass. In the §3 benchmark (local), happy-dom imported faster (~73 vs ~120 ms for jsdom 31, bare Node) and built windows faster (~10 vs ~35 ms). But it was **2–2.3× slower** than jsdom 31 on style-heavy `ByRole` queries. On CSS-heavy suites, measure before swapping.
4. **Jest: run a newer jsdom** through a custom environment: see [stack/jest.md](stack/jest.md) check 6.
5. **Use browser mode only for tests that need a real engine, in their own job.** One user's report: adding 3 browser-mode tests to a 507-test jsdom suite took GitHub Actions from 284 s to 473 s ([#9323](https://github.com/vitest-dev/vitest/issues/9323)). The issue was closed with no root cause found.
   Vitest 5 browser-mode changes: see [stack/vitest.md](stack/vitest.md) Version traps (5.0, 5.0.4).

## 3. CSS: don't process or inject what you don't assert on

Vitest's CSS defaults (`css`, the `vitest:css-disable` plugin, CSS Modules, `css: true`, browser mode): see [stack/vitest.md](stack/vitest.md) check 8.

**Why processed CSS costs time:** every `getComputedStyle` call then matches against all rules. These call it:
- `getByRole` visibility checks. ByRole "can be expensive (particularly with large DOM trees)", and `hidden: true` avoids "expensive visibility checks" ([ByRole](https://testing-library.com/docs/queries/byrole)).
- user-event's pointer-events check, which is "known to be expensive" ([options](https://testing-library.com/docs/user-event/options)).
- jest-dom `toBeVisible`.
- Runtime CSS-in-JS (styled-components, emotion) injects `<style>` from JS, **regardless of `css`**.

**Benchmark (local; synthetic micro-benchmark, not a primary source):**
- **Setup:** 200 buttons in a tree of about 1,000 elements, plus N rules (class, descendant+attribute and `@media`). The DOM is mutated before each query. Each number is the mean of 3 calls to `getAllByRole('button')`, in ms, with @testing-library/dom 10.4.2.
- **Runs:** two independent runs on Node 26.13 and Node 24.22 agreed. The ranges below span both.

| Rules in document | jsdom 31.0.0 | jsdom 26.1.0 (Jest 30 default) | happy-dom 21.0.4 | `{hidden:true}` / `getByText` |
|---|---|---|---|---|
| 0 | 16–17 | 65 | 17–18 | 1–4 |
| 500 | 44–45 | 184–187 | 79–84 | 1–3 |
| 5,000 | 289–295 | **6,500–8,400** | 660–680 | 2–3 |

At 5k rules, removing the CSS cut each query ~18× on jsdom 31, ~37× on happy-dom and ~120× on jsdom 26. Moving jsdom 26→31 cut it ~22–28×, and `hidden: true` cut it 100× or more. jsdom 28.1 added specificity to `getComputedStyle`, 29.x–30.1.x sped it up repeatedly, and 31 replaced the engine ([releases](https://github.com/jsdom/jsdom/releases)). On older jsdom, style rules made queries slow; on jsdom 31 they matter far less. Real apps (Tailwind, CSS-in-JS) may scale differently.

Vite plugins inherited by Vitest (Tailwind, Sass, PostCSS, checker: detection, the `process.env.VITEST` gate, a standalone config): see [stack/vite.md](stack/vite.md) T1. Jest CSS stub (`moduleNameMapper`): see [stack/jest.md](stack/jest.md) check 7.

**Other fixes:**
- **Keep CSS only where tests assert on styles:** use `css: { include: [/critical\.css$/] }` or a browser project.
- **Risk:** tests that assert on computed styles or real class names break. Grep for `toHaveStyle` and `getComputedStyle`.
- **Animations:** `pretendToBeVisual` is `true` in both Vitest's and Jest's jsdom env. It enables `requestAnimationFrame` and doesn't do layout, so animation libraries run real rAF loops. For Motion, set `MotionGlobalConfig.skipAnimations = true` in setup. It is exported from `framer-motion` ≥10.17.0, not 10.16.16, and still present in 14.11.1 and in `motion/react` (package contents).

## 4. Import and transform cost

**Signals:** `import` or `transform` dominates, or `importDurations` lists heavy modules. `selfTime` excludes only "non-externalized imports", so externalized `node_modules` time counts toward the importing file ([TestModule](https://vitest.dev/api/advanced/test-module)).

**Barrels and icon libraries:**
- **Vitest:** importing from the specific module instead of the barrel "reduces amount of transformed files by ~85%" in the docs' example ([profiling](https://vitest.dev/guide/profiling-test-performance)).
- **Jest:** barrel-rewriting Babel plugins: see [stack/jest.md](stack/jest.md) check 10.
- **MUI:** named icon imports "can be up to six times slower" in dev than path imports. Fix with `npx @mui/codemod@latest v5.0.0/path-imports <path>` and enforce with `no-restricted-imports` `{"patterns":[{"regex":"^@mui/[^/]+$"}]}` ([MUI](https://mui.com/material-ui/guides/minimizing-bundle-size/)).
- **lucide-react 1.70:** the `node` condition for `.` resolves to **one CJS bundle**. Under Node resolution (Jest, Vitest-externalized deps) it is one big file, not thousands of modules, so check `importDurations` before rewriting. `lucide-react/icons/*` exists but is **ESM only** (`./dist/esm/icons/*.mjs`), so it can break in CJS Jest.

```bash
git grep -nE "from '(@mui/(material|icons-material)|lodash|react-icons/[a-z]+|date-fns|@/components|\.\./?index)'" -- 'src/**/*.ts*' | wc -l
git ls-files 'src/**/index.ts' 'src/**/index.tsx' | xargs grep -l "export \* from"   # internal barrels
```
**Fixes:**
- **Deep imports**, enforced by a lint rule.
- **Vitest pre-bundling** (`deps.optimizer`): see [stack/vitest.md](stack/vitest.md) check 12.
- **Alias a heavy module** to a stub in the test config only.

**Transform caches:**
- **`NODE_COMPILE_CACHE=<dir>`:** reuses V8 compile results only if the directory survives between runs. Vitest disables it in workers under `v8` coverage ([perf guide](https://vitest.dev/guide/improving-performance)).
- **Vitest** `fsModuleCache` (versions, path, CI persistence) and the open v5 resolver-cache regression ([#11764](https://github.com/vitest-dev/vitest/issues/11764)): see [stack/vitest.md](stack/vitest.md) check 11 and Version traps.
- **Jest** `cacheDirectory`, `transformIgnorePatterns` and transformer choice (`babel-jest`, `@swc/jest`, `ts-jest`, `esbuild-jest`): see [stack/jest.md](stack/jest.md) Cache paths and check 8.

Don't type-check inside the test run. Vitest only does it with `--typecheck`. Run `tsc --noEmit` as a parallel job. TS 7 claims "8x and 12x on full builds" there (cited). Tools that need the compiler API stay on TS 6, run side by side ([TS 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)).

## 5. Setup files and per-test costs

- **Setup files run before every test file.**
  - **Vitest** and **Jest** setup-file behaviour (per test file, the `isolate: false` caveat): see [stack/vitest.md](stack/vitest.md) check 13 and [stack/jest.md](stack/jest.md) check 5.
  - **`globalSetup`** runs once, in the main process, so it can't share in-memory objects with tests.
  - **Detect:** check the `setup` share and read the files. Look for full i18n catalogs, all MSW handlers and fixtures, whole component libraries, polyfill bundles and DB connections.
- **MSW:** the pattern is `beforeAll(listen)`, `afterEach(resetHandlers)`, `afterAll(close)` ([MSW node](https://mswjs.io/docs/integrations/node)).
  - Put it only in projects that make network calls.
  - Lazy-load big fixtures inside resolvers.
  - Fail on unmatched requests so hanging real calls surface: `onUnhandledRequest: 'error'` in MSW 2, `onUnhandledFrame: 'error'` in MSW 3.
- **ByRole cost: maintainer's checklist ([dtl #820](https://github.com/testing-library/dom-testing-library/issues/820), 2020).** Steps are ordered from lowest confidence cost:
  1. latest jsdom
  2. a real browser
  3. `{ hidden: true }`
  4. `getByTestId`
  5. don't filter by `name`

  In the same thread, MUI set `configure({ defaultHidden: true })` (default `false`, [config](https://testing-library.com/docs/dom-testing-library/api-configuration)) for local runs and kept it `false` in CI. Scope queries with `within(container)`. The thread's timings predate jsdom 28–31, so use the §3 table instead.
- **`waitFor` / `findBy*`:** the timeout is `asyncUtilTimeout` = 1000 ms, and the polling interval defaults to 50 ms ([wait-for.js](https://github.com/testing-library/dom-testing-library/blob/main/src/wait-for.js)). A slow query inside `waitFor` reruns every interval. Anti-patterns:
  - `findBy` used to assert absence.
  - `try { await findBy… } catch {}`.
  - A raised global `asyncUtilTimeout`.

  The first two each burn the full timeout.
- **user-event:**
  - **`pointerEventsCheck`:** "very expensive when checking deeply nested nodes". The default is `EachApiCall`. `PointerEventsCheckLevel.EachTarget` or `.Never` reduces it.
  - **`delay`:** defaults to `0`, which still calls `setTimeout` per action. `null` skips it, but is "not recommended" with fake timers ([options](https://testing-library.com/docs/user-event/options)).
  - **Long input:** use `user.paste()` for long text, and `fireEvent` where event semantics aren't under test.
- **Fake timers** remove real waits (debounce, polling, toasts). One trap: DTL only auto-advances fake timers in `waitFor` when a global `jest` exists ([helpers.ts](https://github.com/testing-library/dom-testing-library/blob/main/src/helpers.ts)), so under Vitest it can poll in real time until timeout. Use one of these:
  - `vi.waitFor`, which calls `vi.advanceTimersByTime(interval)` when fake timers are on (5.1.0 dist)
  - `vi.setTimerTickMode('nextTimerAsync')` (4.1+; not in 4.0.18)
  - `shouldAdvanceTime`

  For user-event, pass `advanceTimers: vi.advanceTimersByTime`.

## 6. E2E (Playwright) per-test cost

Production build vs dev server, login once with `storageState`, seeding and network routing, browser installs, traces and video, slow-spec reports and workers: see [stack/playwright.md](stack/playwright.md) Measure and checks 1, 5–10.

## 7. Checklist

| Smell | Detect | Fix and gain |
|---|---|---|
| Global `jsdom`/`happy-dom` with many pure-logic tests | §2 `grep -L` | `projects` split. Saves ~90–500 ms env import per moved file under `isolate: true` (cited) |
| `environment` dominates with `isolate: true` | v5 hint or §1 reporter | `vmThreads`/`vmForks`/`isolate:false`. −67%/−69% on one doctor fixture (cited). Validate with `vitest doctor` |
| `css: true` / `include: [/.+/]` with no style assertions | `grep -n "css" vitest.config.*` | Remove it. ByRole ~18–120× faster with 5k rules removed (local, §3) |
| Jest + jsdom 26 + CSS-in-JS + ByRole | `npm ls jsdom`, ByRole count | custom env on jsdom 31 (~22–28× on style-heavy queries, local), `defaultHidden`, `within` |
| Barrel/icon imports | §4 grep, `importDurations` | deep imports or `deps.optimizer`. ~85% fewer transformed files in the Vitest example (cited) |
| Cold transform cache in CI | no cache for `.jest-cache` / `node_modules/.vitest-cache` | persist the dir. Jest: cache off is "at least two times slower" (cited) |
| Heavy `setupFiles` | `setup` share, read the files | lazy-load, `globalThis` guard, scope to a project (heuristic) |
| `waitFor`/`findBy` burning timeouts | `grep -rn "catch {}" ` near `findBy`; slow tests ≈ 1000 ms multiples | `queryBy` + `expect(...).toBeNull()`, fake timers |

Also check: Vite plugins inherited by tests ([stack/vite.md](stack/vite.md) T1), `ts-jest` type-checking ([stack/jest.md](stack/jest.md) check 8), UI login per test, E2E against a dev server, and record-always traces or video ([stack/playwright.md](stack/playwright.md) checks 5, 6 and 10).
