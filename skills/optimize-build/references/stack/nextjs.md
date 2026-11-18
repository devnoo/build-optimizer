# nextjs — optimize-build stack reference

Use when: detect-stack.sh reported `nextjs`. Lanes: bundle, cache.

Checked 2026-11-09 and re-verified 2026-11-18 against the docs, the release posts and the source at tag `v16.4.5` (16.4.6 is the latest; 16.3.0 shipped 2026-08-03 and 16.4.0 on 2026-10-06). **(vendor)** = Vercel's own benchmark. **(source)** = read in `vercel/next.js@v16.4.5` and not stated in the docs. Get the repo's version first with `npm ls next`. Paths are relative to the **Next app dir** (the folder with `next.config.*`), not the monorepo root.

## Measure

- **Phase lines in the CI log.** Next ≥16 prints a duration for each phase:
  ```bash
  gh run view <id> --log | grep -E 'Next\.js 1[0-9]|Compiled successfully in|Finished TypeScript|Collecting page data using|Generating static pages using .* in|Collecting build traces in|Finalizing page optimization in|No build cache found'
  ```
  The header `▲ Next.js 16.x (Turbopack)` or `(webpack)` names the bundler. `Finished TypeScript config validation in` means `ignoreBuildErrors` is on. `Collecting build traces` appears only on webpack builds (source). `Generating static pages using N workers (x/y) in` shows prerender parallelism.
- **`.next/trace-build`** (16.0+, source) is JSON lines of top-level spans, durations in µs: `next-build`, `run-turbopack`/`run-webpack`, `run-typescript`, `static-check`, `static-generation`, `collect-build-traces`, `output-standalone`. In 16.2+ it also has `turbopack-persistence` and `turbopack-compaction`, which are the cache write cost. 16.4+ adds `turbopack-module-graph`, `turbopack-write-entrypoints` and `turbopack-emit`, which time compilation and output emit, not the cache. Upload it as an artifact, then:
  ```bash
  jq -s -r 'add | group_by(.name)[] | [((map(.duration)|add)/1e6*10|round/10), .[0].name] | @tsv' .next/trace-build | sort -rn
  ```
  On ≤15, `.next/trace` has the same format with many more spans. Each `next build` starts both files fresh: on 16.4 the clean keeps `trace` but deletes `trace-build`, and both are opened in truncate mode (source), so copy them before the next build.
- **CPU profile:** `next build --experimental-cpu-prof` (16.2+) writes `.next-profiles/build-main-*` `.cpuprofile` files, plus `build-turbopack-*` on 16.2–16.3 only (16.4 compiles in the main process, so Turbopack's JS side is in `build-main-*`; source, though the CLI docs still list it) (on webpack: `build-webpack-{client,server,edge-server}-*`). Open them in the Chrome DevTools Performance tab.
- **Per-module Turbopack time:** `next build --internal-trace [all|overview]` writes `.next-profiles/trace-turbopack.bin`. The build flag exists in 16.3+ source; the docs only show it for `next dev`. Run `npx next internal trace <file>`, open https://trace.nextjs.org and pick "Spans in order".
- **webpack/SWC per file:** `experimental.swcTraceProfiling: true` writes `.next/swc-trace-profile-<ts>.json` (open in Perfetto or speedscope).
- **Local A/B** (same machine, ≥3 runs each): cold `rm -rf .next && next build` vs a second warm run isolates the FS cache. `--webpack` vs the default isolates the bundler. `--experimental-build-mode compile` (experimental) skips type checking and prerendering (source). In the App Router, type checking runs **after** compilation, serially, so it adds to the critical path (source).

## Checks

1. **Bundler is webpack.** **Check** `grep -nE 'next build.*--webpack' package.json .github/workflows/*.y*ml; grep -nE '\bwebpack\s*[:(]' next.config.*`, the `(webpack)` log header, or `next` <16 without `--turbopack`. **Good** `next` ≥16 with a plain `next build`.
   **Fix** remove `--webpack`; port `webpack()` tweaks to `turbopack.rules` (webpack loaders) or `turbopack.resolveAlias`. On webpack only, barrel-heavy packages need `experimental.optimizePackageImports`; Turbopack analyzes imports itself. **Gain** "2–5× faster production builds" (vendor, Next 16).
   **Risk** Turbopack does not support webpack plugins, `sassOptions.functions`, Yarn PnP or Sass `~` imports. CSS-module order follows JS import order, and Lightning CSS keeps 5 decimals where webpack keeps 10. On 16, a `webpack` key with no `turbopack` key makes a plain `next build` fail (source); plugins often add that key, and `next build --turbopack` ignores it.
2. **A Babel config is present.** **Check** `ls .babelrc .babelrc.{json,js,mjs,cjs} babel.config.{js,json,mjs,cjs} 2>/dev/null` in the app dir. This is the exact list Next checks (source); `babel.config.ts` and the `package.json` `babel` key are not detected. **Good** none.
   **Fix** delete it and use SWC built-ins `compiler.{styledComponents,emotion,relay,removeConsole,reactRemoveProperties,define}`. If it exists only for Jest, switch to `next/jest` (SWC transform), or rename it so Next misses it and pass it to `babel-jest` via `configFile` (heuristic). Escape hatches: `experimental.turbopackUseBuiltinBabel: false` makes Turbopack ignore config files; `experimental.forceSwcTransforms: true` does the same on webpack.
   **Gain** SWC is "17x faster than Babel" per file (vendor); the build-level gain is unmeasured. **Risk** on Turbopack (16+) Babel runs **in addition to** SWC on files outside `node_modules`, in Node child processes. On webpack, a Babel config drops SWC entirely. Babel-only plugins (macros, istanbul coverage) stop applying, so keep them in a separate coverage build.
3. **React Compiler runs through Babel.** **Check** `grep -nE 'reactCompiler|turbopackRustReactCompiler' next.config.*`; `babel-plugin-react-compiler` in deps. **Good** off, or on 16.3+ Turbopack `experimental.turbopackRustReactCompiler: true`, which needs no Babel plugin.
   **Fix** compare "Compiled successfully in" with the compiler on and off; try the Rust port. **Gain** Babel path: "expect compile times … to be higher" (Next 16). The docs also say an SWC pre-filter limits it to files with JSX or hooks, so the impact is "small and localized". Rust port: "compilation wins of 20-50%" on v0 (vendor, 16.3); 16.4 cut the compiler's compile time 15% and memory 30% (vendor). The −34%/−46% figures in the 16.3 post measure `next dev` time-to-page, not builds.
   **Risk** the Rust port is experimental and Turbopack-only (webpack throws). Turning the compiler off changes runtime memoization.
4. **Type checking runs inside `next build`.** **Check** the share of "Finished TypeScript in" (or `run-typescript`); a separate `tsc`/`typecheck` job in `.github/workflows`; `grep -n ignoreBuildErrors next.config.*`.
   **Facts** `next build` type-checks unless `typescript.ignoreBuildErrors: true`. In 16.3+ it runs the project-local `tsc` CLI (`experimental.useTypeScriptCli`, default `true`; `false` selects the API path, which exits on TS 7). It checks the whole tsconfig project, tests included, and `--debug-build-paths` does not narrow it. With tsconfig `incremental`/`composite`, Next passes `--tsBuildInfoFile .next/cache/.tsbuildinfo` (source).
   **Good** exactly one check per program: a parallel cached `tsc` job + `ignoreBuildErrors: true`, **or** `next build` alone. **Fix** pick one. In a standalone job run `next typegen && tsc --noEmit`, because typegen writes the route types and `next-env.d.ts`. `typescript@^7` works on the 16.3+ CLI path (gain: build-steps.md §3).
   **Gain** the "Finished TypeScript" time leaves the build's critical path (measured in your log). **Risk** never drop both. With `ignoreBuildErrors` on, Next "dangerously" ships type errors unless the `tsc` job is required for merge.
5. **Lint runs inside `next build` (≤15).** **Check** `next` <16 without `eslint.ignoreDuringBuilds` lints `pages/ app/ components/ lib/ src/` during the build; also look for `next lint` in scripts. **Good** 16+: the build never lints, and lint runs once in its own job.
   **Fix** ≤15: set `eslint: { ignoreDuringBuilds: true }` once a lint job exists. 16: `next lint` is gone; migrate with `npx @next/codemod@canary next-lint-to-eslint-cli .`. The `eslint` config key is ignored with a warning (source). **Gain** the lint time (typical, unmeasured; A/B the flag). **Risk** lint must still gate merges.
6. **`.next/cache` is not restored** (cache lane; see Cache paths). **Check** `grep -nE '\.next/cache' .github/workflows/*.y*ml`; `⚠ No build cache found` in the log (docs page "No Cache Detected"). Next prints it only when it detects CI, not on hosts with built-in Next support, and it only checks that the directory exists (source).
   **Good** restored before `next build` ("Builds only get faster when that directory is restored", docs) and saved from the default branch. If CI can never restore it, set `experimental.turbopackFileSystemCacheForBuild: false` so the build skips writing it. **Gain** Turbopack compile, cold→cached: 21 s→9.2 s, 66 s→46 s, 30 s→5.5 s (vendor, 16.3). Skipping the write saves the `turbopack-persistence`/`turbopack-compaction` spans.
   **Risk** restore + save must cost less than the compile time saved (ci-github-caching.md rule zero); 16.4 shrank the cache 20–25%. On first rollout, confirm the output matches a cold build. PR jobs that never save can set `TURBO_ENGINE_READ_ONLY=1` to open the cache read-only. That is source-only and undocumented, so verify with the `turbopack-persistence` span.
7. **Every build writes source maps.** **Check** `grep -nE 'productionBrowserSourceMaps|serverSourceMaps|enablePrerenderSourceMaps|withSentryConfig' next.config.*`. **Good** only the build that uploads or deploys maps writes them.
   **Fix** gate them on an env var; in builds, `turbopackSourceMaps` follows `productionBrowserSourceMaps`. **Gain** typical, unmeasured (docs: maps cost build memory, and plugins may turn them on). **Risk** PR builds lose readable stack traces.
8. **Prerendering dominates** ("Generating static pages … in" or `static-generation`). **Check** the worker count vs runner vCPUs, thousands of `generateStaticParams` paths, slow build-time `fetch`. **Facts** workers default to `experimental.cpus` = CPUs − 1, minimum 1 (source). Docs options: `experimental.staticGenerationMaxConcurrency` (default 8 pages per worker), `staticGenerationMinPagesPerWorker` (25) and `staticGenerationRetryCount`.
   **Fix** return only a subset from `generateStaticParams` and render the rest on demand (ISR); use a larger runner when pages ≫ workers × 25 (heuristic). Cached build-time fetches land in `.next/cache/fetch-cache`. **Gain** typical, unmeasured. **Risk** first visits to pages not prerendered are slower, and a restored fetch-cache can bake stale data into the build.
9. **Output tracing and standalone output.** **Check** "Collecting build traces in" (webpack only) or the `output-standalone` span; `grep -nE 'outputFileTracing(Root|Includes|Excludes)|output:' next.config.*`; in a monorepo, the duplicate-lockfile warning (Next guessed the wrong root). **Good** Turbopack, which traces inside the bundler (`.nft.json` with `fileHashes`).
   **Fix** move to Turbopack. No `**/*` at the repo root in `outputFileTracingIncludes` (docs); exclude large unused dirs with `outputFileTracingExcludes`. In monorepos set `outputFileTracingRoot`, which must equal `turbopack.root` (16.4.5 warns when they differ). **Gain** typical, unmeasured. **Risk** an over-broad exclude means a file is missing at runtime; smoke-test with `node .next/standalone/server.js`.
10. **Loaders and CSS tooling.** **Check** `turbopack.rules` loaders (e.g. `@svgr/webpack`), PostCSS plugins, Tailwind v3 `content` globs reaching `node_modules` (Tailwind ≥3.4.8 warns, docs). **Fix** Turbopack runs Babel, PostCSS and loaders in Node child processes. `experimental.turbopackPluginRuntimeStrategy: 'workerThreads'` (16.4, experimental) runs them in-process, but falls back on Node ≥24.13.1. **Gain** typical, unmeasured. **Risk** the flag is experimental.

## Cache paths

| Path (under the app dir) | Writer | Notes |
|---|---|---|
| `.next/cache/turbopack/` | `next build` on Turbopack, on by default since **16.3.0** | One DB per Next version (`v<next>-<sha>`), so any `next` bump is a cold build. On CI, DBs for other versions are deleted and the DB is written once at shutdown (source). Opt out with `experimental.turbopackFileSystemCacheForBuild: false`. `experimental.turbopackGc` (16.4, default `false`) prunes it. |
| `.next/cache/webpack/` | `next build --webpack` | The cache version includes Next's absolute install path, its version and the config (source), so a different checkout or container path is a miss. |
| `.next/cache/.tsbuildinfo` | type check | Written only when tsconfig sets `incremental`/`composite`; `create-next-app` sets `incremental: true`. |
| `.next/cache/fetch-cache/` | prerender data cache | Kept here "so it can be persisted across deploys" (source comment). |
| `.next/cache/eslint/` | ≤15 lint during the build | Not written on 16. |
| `.next/cache/images/` | `next start` image optimizer | Exists only if the job served the app (E2E). It is runtime state, so leave it out of build caches. |
| `.next/dev/cache/turbopack/` | `next dev` (on by default since 16.1) | Not used by `next build`. Don't cache it in CI. |

- **Official GHA recipe** ([CI caching](https://nextjs.org/docs/app/guides/ci-build-caching); the docs show `actions/cache@v4`, use v6). Paths are `~/.npm` and `${{ github.workspace }}/.next/cache`. Key: `${{ runner.os }}-nextjs-${{ hashFiles('**/package-lock.json') }}-${{ hashFiles('**/*.js', '**/*.jsx', '**/*.ts', '**/*.tsx') }}`. `restore-keys`: `${{ runner.os }}-nextjs-${{ hashFiles('**/package-lock.json') }}-`.
- **Correct the recipe:**
  1. For monorepos or a custom `distDir`, the path is `<app>/<distDir>/cache`, not the workspace root.
  2. The source glob walks `node_modules` if it runs after install, and `hashFiles` stops after 120 s. Use `${{ github.sha }}` as the last key part (ci-github-caching.md anti-pattern 4).
  3. Drop `~/.npm` when setup-node already caches it.
  4. Add `runner.arch` to the key.
  5. Save only from the default branch (fix A).
  ```yaml
  - uses: actions/cache/restore@v6
    id: next
    with:
      path: apps/web/.next/cache
      key: next-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('pnpm-lock.yaml') }}-${{ github.sha }}
      restore-keys: next-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('pnpm-lock.yaml') }}-
  # … install, then next build …
  - uses: actions/cache/save@v6
    if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch)
    with: { path: apps/web/.next/cache, key: "${{ steps.next.outputs.cache-primary-key }}" }
  ```
- **Restore order:** any time after checkout and before `next build`. Installs never touch `.next/`, and `next build` cleans `.next/` but keeps `cache/` (source). Restoring **before** install keeps any `hashFiles` glob out of `node_modules`.
- **Turbo/Nx:** a task-cache hit skips `next build`, so `.next/cache` is not needed. Turborepo `outputs` should be `[".next/**", "!.next/cache/**", "!.next/dev/**"]` ([turbo.json](https://turborepo.dev/docs/reference/configuration)). The remote cache never carries `.next/cache`, so a turbo miss needs `actions/cache`.
- **Docker:** a containerized build does "not carry `.next/cache` over unless you cache or mount it explicitly". Use `RUN --mount=type=cache,target=/app/.next/cache …`, and see the docker lane for how GHA persists that mount.
- **Is it worth it?** Compare `Cache Size: ~N MB` and the restore step time against the cold-minus-warm difference in `run-turbopack`.

## Version traps

- **15.0:** `outputFileTracingRoot/Includes/Excludes` moved out of `experimental` (the old keys warn). `outputFileTracing: false` was removed, so tracing is always on. `swcMinify` was removed. `serverComponentsExternalPackages` → `serverExternalPackages`; `bundlePagesExternals` → `bundlePagesRouterDependencies`.
- **≤15:** `next build` lints and uses webpack. Turbopack builds were experimental in 15.3 (`--turbopack`) and beta in 15.5. 15.5 canary's `experimental.turbopackPersistentCaching` is now `turbopackFileSystemCacheForDev`/`…ForBuild`; the old keys stop the build with a rename hint (source).
- **16.0 (2025-10-21):**
  - Turbopack is the default bundler (opt out with `--webpack`), and a `webpack` config with no `turbopack` config fails a plain build.
  - `experimental.turbopack` → `turbopack`; `experimental.reactCompiler` → `reactCompiler`.
  - A Babel config auto-enables Babel on Turbopack (before 16 it was a hard error).
  - `next lint` and the `eslint` key were removed, and the build no longer lints.
  - The `size`/`First Load JS` columns are gone; the output now prints per-phase timings and writes `.next/trace-build`.
  - `next dev` writes to `.next/dev`. Requires Node ≥20.9 and TS ≥5.1.
- **16.1:** dev FS cache on by default; `next experimental-analyze` added (now `next analyze`). **16.2:** `next build --experimental-cpu-prof` added.
- **16.3 (2026-08-03):** build FS cache on by default. `useTypeScriptCli` defaults to `true` (the key is absent in 16.2.0), so the build runs `tsc` over the whole project and TS 7 works. Added `experimental.turbopackRustReactCompiler` and `next build --internal-trace`.
- **16.4 (2026-10-06):** disk cache 20–25% smaller. Added `experimental.turbopackGc` (applies to builds too) and `turbopackPluginRuntimeStrategy`. Rust React Compiler fast-check. `eslint-config-next@16.4+` supports ESLint 10.

## Sources

- Release posts: [Next 16](https://nextjs.org/blog/next-16), [16.3](https://nextjs.org/blog/next-16-3), [16.3 Turbopack](https://nextjs.org/blog/next-16-3-turbopack), [16.4](https://nextjs.org/blog/next-16-4). Upgrade guides: [v16](https://nextjs.org/docs/app/guides/upgrading/version-16), [v15](https://nextjs.org/docs/app/guides/upgrading/version-15)
- Cache: [turbopackFileSystemCache](https://nextjs.org/docs/app/api-reference/config/next-config-js/turbopackFileSystemCache), [turbopackGc](https://nextjs.org/docs/app/api-reference/config/next-config-js/turbopackGc), [CI build caching](https://nextjs.org/docs/app/guides/ci-build-caching), [No Cache Detected](https://nextjs.org/docs/messages/no-cache)
- Bundler and CLI: [Turbopack](https://nextjs.org/docs/app/api-reference/turbopack), [next CLI](https://nextjs.org/docs/app/api-reference/cli/next), [Building](https://nextjs.org/docs/app/guides/building), [Local dev / tracing](https://nextjs.org/docs/app/guides/local-development), [Memory usage](https://nextjs.org/docs/app/guides/memory-usage)
- TypeScript: [TypeScript](https://nextjs.org/docs/app/api-reference/config/typescript), [useTypeScriptCli](https://nextjs.org/docs/app/api-reference/config/next-config-js/useTypeScriptCli). Compilers: [reactCompiler](https://nextjs.org/docs/app/api-reference/config/next-config-js/reactCompiler), [turbopackRustReactCompiler](https://nextjs.org/docs/app/api-reference/config/next-config-js/turbopackRustReactCompiler), [Next.js Compiler](https://nextjs.org/docs/architecture/nextjs-compiler), [SWC disabled](https://nextjs.org/docs/messages/swc-disabled)
- Output and config: [output / tracing](https://nextjs.org/docs/app/api-reference/config/next-config-js/output), [staticGeneration*](https://nextjs.org/docs/app/api-reference/config/next-config-js/staticGeneration), [ESLint v15](https://nextjs.org/docs/15/app/api-reference/config/eslint), [Package bundling](https://nextjs.org/docs/app/guides/package-bundling), [turbo.json outputs](https://turborepo.dev/docs/reference/configuration)
- Source @ [v16.4.5](https://github.com/vercel/next.js/tree/v16.4.5): `packages/next/src/{bin/next.ts, build/index.ts, build/get-babel-config-file.ts, build/webpack-config.ts, trace/report/to-json-build.ts, lib/typescript/runTypeCheckCli.ts, server/config-shared.ts, server/config.ts}`, `crates/next-napi-bindings/src/next_api/turbopack_ctx.rs`, `turbopack/crates/turbo-tasks-backend/src/database/db_versioning.rs`
