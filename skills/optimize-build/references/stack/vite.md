# vite — optimize-build stack reference

Use when: detect-stack.sh reported `vite`. Lanes: test, bundle.

Checked 2026-11-09: vite **8.3.7** (latest; v7 line 7.3.x), rolldown 1.3.1, @vitejs/plugin-react 6.3.0, @tailwindcss/vite 4.3.5, vitest 5.1.0 (`npm view <pkg> version`). Read the repo's versions first: `npm ls vite rolldown-vite @vitejs/plugin-react @vitejs/plugin-react-swc @rolldown/plugin-babel vitest`. **(local)** = run on 2026-11-09 (Node 26.13, one Apple-silicon machine) on a synthetic app: 400 React components importing `@mui/material` 9.5, `@mui/icons-material` 9.5, `lodash-es` and `date-fns` 4.4 through their barrels (12,996 modules). Wall times include `npx` start-up, 4 runs each. They show direction, not this repo's gain. Vitest-only knobs (pools, `deps.optimizer`, `fsModuleCache`) are in `vitest.md`.

## Measure

```bash
# bundle lane: Vite's phase lines (local, 8.3.7): "building client environment for production..." "transforming..."
# "✓ N modules transformed." "rendering chunks..." "computing gzip size..." "✓ built in 0.64s"
gh run view <run-id> --log --job <job-id> | grep -E 'vite v[0-9]|building .* environment|modules transformed|built in|PLUGIN_TIMINGS|computing gzip|larger than'
npx vite build --profile            # writes ./vite-profile-0.cpuprofile (local); open in speedscope or Chrome DevTools
npx vite build --debug [feat] --filter <str>   # DEBUG=vite:<feat>; bare --debug = vite:*, which omits plugin-transform/plugin-resolve (name them)

# test lane: per-plugin transform time inside Vitest (local, Vitest 5.1 + Vite 8.3.7)
DEBUG=vite:plugin-transform npx vitest run --no-fsModuleCache 2>&1 | awk '{for(i=1;i<=NF;i++) if($i ~ /vite:plugin-transform/){t[$(i+2)]+=$(i+1); n[$(i+2)]++}}
  END{for(p in t) printf "%9.1f ms %5d  %s\n", t[p], n[p], p}' | sort -rn | head
```
- **`N modules transformed` far above the repo's own source-file count** means barrels or icon packs are pulled in whole (check S1). One `building … environment` line per environment: SSR frameworks build client and server.
- **`[PLUGIN_TIMINGS]` (Vite 8):** Rolldown's `checks.bundlerTimings` (default `true`; replaces the deprecated `pluginTimings`). It fires only when the build takes over 3 s and plugin time exceeds 100× the link stage. Rows appear only for callbacks costing ≥1 s, and the time is CPU time summed over concurrent hooks. Watch and dev rebuilds never print it ([checks](https://rolldown.rs/options/checks)). Local output: `JavaScript callbacks ran for 5.5s of this 5.5s build (100%)` / `- plugin slow-plugin transform (100%, 5.5s, 57 calls)`. Rollup-based Vite ≤7 has no equivalent, so use `--profile` there.
- **The plugin-transform debug line is written only when a hook returns a result** (8.3.7 dist). A plugin that burns time and returns nothing never shows up, so A/B it by removing the plugin. `--no-fsModuleCache` is needed on Vitest ≥5.0.4: with a warm module cache, nothing is transformed and nothing is logged (local). On v4 the cache is off by default, so drop the flag. `vite:plugin-resolve` does the same for `resolveId`.
- **Dev server / E2E against `vite`:** `vite --debug transform` lists per-file transform times. `vite --profile` records a `.cpuprofile` when you press `p + enter` ([perf guide](https://vite.dev/guide/performance)). vite-plugin-inspect v12 needs Vite 8 plus `@vitejs/devtools` ≥0.7; use v11 on older Vite ([repo](https://github.com/antfu-collective/vite-plugin-inspect)).

## Checks

### T1. Vite plugins that leak into Vitest (test lane)
- **Check** `rg -n "tailwind|postcss|sass|less|stylus|svgr|checker|pwa|inspect|legacy|sentry|visualizer|compression|babel|mdx" vite.config.* vitest.config.* package.json postcss.config.*`. Vitest inherits these through a `test` key in `vite.config`, `mergeConfig`, or v5 `extends: true`. A `vitest.config.*` "will **override**" `vite.config`, and then all of `vite.config`'s options "will be **ignored**" ([Vitest config](https://vitest.dev/config/)). Then rank plugins with the debug recipe above.
- **Facts (local):**
  - Under Vitest the config sees `command: 'serve'`, `mode: 'test'`, `process.env.VITEST === 'true'` and `NODE_ENV === 'test'` before `vite.config` loads.
  - Plugins with `apply: 'build'` are skipped. Plugins with `apply: 'serve'` or no `apply` run.
  - User `enforce: 'pre'` CSS plugins run **before** `vitest:css-disable` and see the full CSS. `@tailwindcss/vite`'s `generate:serve` expanded `@import "tailwindcss"` from 23 to 4,614 chars, and Vitest then discarded the output.
  - Vite's built-in CSS pipeline (Sass/Less) does **not** run unless `test.css` matches. A broken `.module.scss` passed by default and failed with `css: true`. PostCSS goes through the same `vite:css` plugin, so it is skipped too (inferred).
- **Good** The debug table is led by `vite:import-analysis`, `vite:oxc` and the framework plugin.
- **Fix** Gate with `!process.env.VITEST && plugin()`, or `mode !== 'test'` in a function config. Mark build-only plugins `apply: 'build'`. Or write a standalone `vitest.config.ts` that re-adds only the framework plugin and aliases.
- **Gain (local)** Tailwind costs one transform per distinct CSS module per run, because workers share one Vite server: 46 ms for 2 transforms, and the run went 350 → 310 ms. vite-plugin-checker 1.0.0 made no difference (0.46 vs 0.47 s). Per-file plugins scale with file count (T2).
- **Risk** Tests that assert on real class names or computed styles break. Plugins that provide virtual modules or query imports (`virtual:pwa-register`, svgr `?react`, MDX) must stay, or be aliased to stubs, or imports fail.

### T2. Babel back in the transform path (React Compiler, plugin-react v5 `babel`, plugin-react-swc)
- **Check** `rg -n "babel|reactCompiler|react-compiler|plugin-react-swc" vite.config.* package.json`.
- **Facts** `@vitejs/plugin-react` v6 (Vite 8) dropped Babel: "Vite 8+ can handle React Refresh Transform by Oxc". The React Compiler is added back with `babel({ presets: [reactCompilerPreset()] })` from `@rolldown/plugin-babel` ([plugin-react](https://github.com/vitejs/vite-plugin-react/tree/main/packages/plugin-react)). In the 6.3.0 dist, `reactCompilerPreset` applies only where `consumer === 'client'`. So `environment: 'node'` tests skip it, while happy-dom tests pay for it (local). jsdom also uses the client optimizer, so it probably pays too (inferred).
- **Fix**
  - Exclude non-React code with `myPreset.rolldown.filter.id.exclude = ['src/utils/**']`, or use `compilationMode: 'annotation'`.
  - Gate the compiler out of unit tests.
  - On Vite 8, move from plugin-react-swc to plugin-react unless you use SWC plugins. The SWC README says "we recommend using it instead" ([swc](https://github.com/vitejs/vite-plugin-react/tree/main/packages/plugin-react-swc)).
- **Gain (local)** The compiler cost 545 ms of plugin time over 400 files in happy-dom (~1.4 ms/file), and added ~0.26 s (≈45%) to `vite build`'s `built in` time.
- **Risk** Gated tests no longer run compiled output, so keep E2E (or one job) on the compiled build. 6.0.3 shipped a non-linear filter that regressed performance, fixed in 6.0.5 ([CHANGELOG](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react/CHANGELOG.md)).

### S1. Barrel files and icon packs (test + bundle lanes)
- **Check**
  - `git ls-files '*/index.ts' '*/index.tsx' '*/index.js' | xargs grep -l "export \* from"`.
  - Compare `modules transformed` against your source-file count.
  - Read the dependencies' `sideEffects`: `node -p "require('<pkg>/package.json').sideEffects"`.
- **Facts**
  - Importing one API from a barrel makes Vite fetch and transform every re-exported file in dev and in tests ([perf guide](https://vite.dev/guide/performance)).
  - Rolldown `experimental.lazyBarrel` (default `false`) "avoids compiling unused re-export modules in side-effect-free barrel modules" ([experimental](https://rolldown.rs/options/experimental)).
  - It works in Vite 8 via `build.rolldownOptions.experimental.lazyBarrel: true`, but only for barrels marked side-effect-free. On a local barrel without `sideEffects` it had no effect (57 modules either way); with `sideEffects` it went 57 → 7 (local).
  - Barrels with >5,000 re-exports (e.g. `@mui/icons-material`, 10,611) still pay a resolve per re-export. Rolldown logs `LARGE_BARREL_MODULES` and suggests `@rolldown/plugin-transform-imports` ([lazy barrel](https://rolldown.rs/in-depth/lazy-barrel-optimization)).
- **Fix**
  - Build: enable `lazyBarrel`, and add `"sideEffects": false` (or a list such as `["*.css"]`) to internal packages.
  - Tests and dev: deep imports enforced by a lint rule. Vitest pre-bundling is covered in `vitest.md` #12.
- **Gain** Rolldown's docs report 2,986 → 250 modules and 2–4× faster builds. Local: 12,996 → 1,432 modules and 0.97 → 0.59 s wall.
- **Risk** Experimental, and "planned to be removed" (the docs ask users who need to opt out to file an issue). A wrong `sideEffects: false` drops side-effect imports (CSS, polyfills, registrations), so diff the bundle and run E2E.

### S2. Resolve work: extension guessing, tsconfig paths
- **Check** `rg -n "extensions|tsconfigPaths|vite-tsconfig-paths" vite.config.*`.
- **Facts** `resolve.extensions` defaults to `['.mjs','.js','.mts','.ts','.jsx','.tsx','.json']`, so `./Component` → `.jsx` costs 6 filesystem checks. Fix it in the imports, not by adding extensions, and set `"moduleResolution": "bundler"` + `"allowImportingTsExtensions": true` ([perf guide](https://vite.dev/guide/performance)). `resolve.tsconfigPaths` (Vite 8, default `false`) "has a small performance cost" ([Vite 8](https://vite.dev/blog/announcing-vite8)).
- **Gain** Typical, unmeasured. **Risk** Codemod churn. Vitest 5 has an open slowdown with `tsconfigPaths` ([#11764](https://github.com/vitest-dev/vitest/issues/11764), `test-environment.md` §4).

### B1. Still bundling with Rollup (Vite ≤7)
- **Check** The `vite v7.`/`v6.` line in the build log, or `npm ls vite rolldown-vite`.
- **Good** Vite ≥8: Rolldown bundles and Oxc transforms and minifies.
- **Fix** Upgrade (see Version traps). For large apps, the docs advise trying `rolldown-vite` on Vite 7 first "to isolate any Rolldown-specific issues" ([Vite 8](https://vite.dev/blog/announcing-vite8)).
- **Gain** Cited (user reports, not independent): Linear 46 s → 6 s, Ramp −57%, Beehiiv −64%, Mercedes-Benz.io up to −38%, and Rolldown "10-30x faster than Rollup". Local, same app: 7.3.8 → 8.3.7 went from 2.8 s to 0.97 s wall ("built in" 2.47 → 0.64 s).
- **Risk** Plugins that use hooks Rolldown dropped, `manualChunks` objects, `system`/`amd` formats, native-decorator lowering. Vite 8 is ~15 MB larger to install.

### B2. A slow plugin in the build
- **Check** `PLUGIN_TIMINGS` in the CI log (Vite 8), or `--profile` (≤7). Usual suspects: Sentry or other sourcemap uploaders, PWA, image optimizers, Babel, `vite-plugin-checker`.
- **Fix**
  - Register upload and deploy plugins only in the job that deploys.
  - Use `apply: 'build'`, or `apply(config, { command })` returning false, to keep plugins out of dev and test.
  - Plugin authors: add hook filters (`transform: { filter: { id: /\.css$/ }, handler }`), supported in Vite 6.3.0+ and Rollup 4.38.0+ ([plugin API](https://vite.dev/guide/api-plugin)). Keep `config`/`configResolved`/`buildStart` light, dynamic-`import()` heavy dependencies, and bail out of `resolveId`/`load`/`transform` early ([perf guide](https://vite.dev/guide/performance)).
- **Gain** The plugin's share in the warning. Rolldown's benchmark: 10 unfiltered JS plugins took 2,792 ms vs 745 ms filtered (3.74×) ([hook filter](https://rolldown.rs/in-depth/why-plugin-hook-filter)).
- **Risk** The deploy build must still upload maps or emit the PWA manifest.

### B3. Minifier
- **Check** `rg -n "minify|terserOptions|cssMinify" vite.config.*`, `npm ls terser esbuild`.
- **Good** Vite 8 defaults: `build.minify: 'oxc'` (`false` for SSR) and `cssMinify: 'lightningcss'` ([build options](https://vite.dev/config/build-options)).
- **Fix** Drop `minify: 'terser'` unless a terser-only option is needed. `'esbuild'` is deprecated in 8 and needs `esbuild` installed. Build bundles that only feed tests with `--minify false`.
- **Gain** The docs say Oxc is "30 ~ 90x faster than terser" at "0.5 ~ 2% worse compression". Local: terser added 1.2 s on Vite 8 (0.97 → 2.2 s) and 1.6 s on Vite 7. `minify: false` saved only ~70 ms.
- **Risk** Bundles grow 0.5–2%. Rolldown doesn't support property mangling (`mangleProps`).

### B4. Sourcemaps and their upload in PR builds
- **Check** `rg -n "sourcemap|sentryVitePlugin|@sentry/vite|codecov" vite.config.*`. The default `build.sourcemap` is `false`. `--sourcemap` accepts `true|inline|hidden` ([CLI](https://vite.dev/guide/cli)).
- **Facts (local)** Generating maps (a 3.6 MB map) stayed within run-to-run noise on both 7.3.8 and 8.3.7. The cost is the upload or processing plugin. Sentry: "only upload source maps for production builds and in CI" ([Sentry](https://docs.sentry.io/platforms/javascript/sourcemaps/uploading/vite)).
- **Fix** Gate both on the deploy job, e.g. `sourcemap: process.env.UPLOAD_MAPS ? 'hidden' : false`, and add the upload plugin only then.
- **Gain** The upload plugin's step time or `PLUGIN_TIMINGS` share. Generation alone: ~0 (local). **Risk** Prod errors lose maps if the deploy job misses the flag.

### B5. `reportCompressedSize`, Sass compiler
- `build.reportCompressedSize` (default `true`): "disabling this may increase build performance for large projects" ([build options](https://vite.dev/config/build-options)). Set it to `false` in CI and remove the `computing gzip size...` phase. Local: within noise with one 708 kB chunk, so the gain grows with chunk count (unmeasured). Risk: the gzip column disappears from logs.
- Sass: "Use CSS instead of Sass/Less/Stylus when possible" ([perf guide](https://vite.dev/guide/performance)). Otherwise "For the best performance, it's recommended to install the `sass-embedded` package". `css.preprocessorMaxWorkers` defaults to `true` (CPUs − 1) ([shared options](https://vite.dev/config/shared-options)). Check `npm ls sass sass-embedded`. Gain unmeasured.

### O1. Dev-server consumers in CI: E2E against `vite`, Vitest browser mode
- **Check**
  - Grep the job log for `dependencies optimized:`, `optimized dependencies changed. reloading`, `to optimizeDeps.include` or `optimizeDeps.needsInterop` (strings from the 8.3.7 dist).
  - `rg -n "\-\-force|optimizeDeps" vite.config.* package.json .github/workflows`.
- **Facts** Pre-bundling "only applies in development mode" ([pre-bundling](https://vite.dev/guide/dep-pre-bundling)), so `optimizeDeps` never affects `vite build`. When a dependency is discovered late, Vite re-bundles and reloads the page. Vitest's `deps.optimizer` inherits `optimizeDeps` ([deps](https://vitest.dev/config/deps)). That browser mode hits the same reloads is inferred.
- **Fix**
  - First choice: run E2E against `vite preview` (`playwright.md` #5).
  - Otherwise, add the named dependencies to `optimizeDeps.include` and mixed ESM/CJS ones to `needsInterop`.
  - Set `optimizeDeps.entries` when HTML isn't the entry. Use `holdUntilCrawlEnd: false` only if include plus the scanner cover everything ([options](https://vite.dev/config/dep-optimization-options)).
  - Warm up heavy files with `server.warmup.clientFiles`.
  - Remove `--force` and `optimizeDeps.force` from CI. Cache `deps/` (below).
- **Gain** One re-bundle plus a full reload per late dependency; unmeasured. **Risk** The include list drifts as dependencies change.

## Cache paths

- **`vite build` has no persistent cache.** Builds with 7.3.8 and 8.3.7 wrote nothing to `cacheDir` (local). Rolldown's `experimental.incrementalBuild` (default `false`) is for watch mode. An `actions/cache` step on `node_modules/.vite` or `dist` in a build-only job is waste. To skip rebuilds, use turbo/nx output caching or pass `dist` as an artifact.
- **`cacheDir`** defaults to `node_modules/.vite`, or `.vite` when there is no `package.json` ([shared options](https://vite.dev/config/shared-options)). It holds:
  - `deps/`: the dev pre-bundle, plus `_metadata.json` with `hash`, `configHash`, `lockfileHash` and `browserHash` (local).
  - `vitest/<hash>/results.json`: Vitest's sequencer cache (`vitest.md`).
- **`deps/` is rebuilt** when the lockfile content, the patches folder's mtime, the relevant `vite.config` fields or `NODE_ENV` change, or on `--force` ([pre-bundling](https://vite.dev/guide/dep-pre-bundling)). Cache it only for O1 jobs:
  - Key: `vite-deps-${{ runner.os }}-${{ hashFiles('<lockfile>', 'vite.config.*') }}`.
  - Prefix `restore-keys` is safe, because Vite re-checks the hashes itself (inferred from `_metadata.json`).
  - Restore **after** install, because `npm ci` deletes `node_modules`. Or set `cacheDir: '.cache/vite'`, which moves Vitest's results cache too.
- Vitest's `fsModuleCache` (`node_modules/.vitest-cache`) is in `vitest.md` and `ci-github-caching.md`.

## Version traps

| Version | Change |
|---|---|
| 5.1 | Build-time dependency pre-bundling removed. `optimizeDeps.disabled` is deprecated; to disable, use `noDiscovery: true` with an empty `include` ([options](https://vite.dev/config/dep-optimization-options)). |
| 6.0 | `json.stringify: 'auto'`. Modern Sass API by default. `commonjsOptions.strictRequires: true`. `cssMinify` also runs for SSR. `resolve.conditions` no longer adds `module`/`browser`/`development\|production` internally, so custom lists must spread `defaultClientConditions` ([v6 migration](https://v6.vite.dev/guide/migration)). Hook filters arrive in 6.3.0. |
| 7.0 | Node 20.19+/22.12+. `build.target` defaults to `'baseline-widely-available'`, and `'modules'` is gone. The Sass legacy API is removed, so drop `css.preprocessorOptions.*.api`. `splitVendorChunkPlugin` removed. `optimizeDeps.entries` is always globs ([v7 migration](https://v7.vite.dev/guide/migration)). |
| 8.0 (2026-03-12) | Rolldown + Oxc; esbuild becomes optional. Renamed (deprecated, auto-converted): `build.rollupOptions`→`build.rolldownOptions`, `worker.rollupOptions`→`worker.rolldownOptions`, `esbuild`→`oxc` (`banner`/`footer` have no mapping, `supported` is unsupported), `optimizeDeps.esbuildOptions`→`optimizeDeps.rolldownOptions`, `esbuild.drop`→`build.rolldownOptions.output.minify.compress.drop*`, `transformWithEsbuild`→`transformWithOxc`. `minify`/`cssMinify: 'esbuild'` are deprecated and need `esbuild` installed. `cssMinify` defaults to `lightningcss`. `build.commonjsOptions` is a no-op. Object `manualChunks` is removed; the function form is deprecated in favour of `build.rolldownOptions.output.codeSplitting`. `build.target` moves to Chrome/Edge 111, Firefox 114, Safari 16.4. CJS `default` interop changed (`legacy.inconsistentCjsInterop`) ([migration](https://vite.dev/guide/migration)). New: `resolve.tsconfigPaths` and experimental `devtools`. |
| plugin-react 6.0 | Requires Vite 8 and has no Babel. 6.0.3 regressed compiler-filter performance, fixed in 6.0.5 (2026-07-30). |
| Vitest | v5 needs Vite ≥6.4, v4 needs Vite ≥6 ([v5](https://vitest.dev/guide/migration), [v4](https://v4.vitest.dev/guide/migration)). Upgrading Vite can force a Vitest upgrade. |

## Sources

- Vite: [Vite 8 announcement](https://vite.dev/blog/announcing-vite8), [migration v8](https://vite.dev/guide/migration), [v7](https://v7.vite.dev/guide/migration), [v6](https://v6.vite.dev/guide/migration), [build options](https://vite.dev/config/build-options), [shared options](https://vite.dev/config/shared-options), [dep optimization options](https://vite.dev/config/dep-optimization-options), [dep pre-bundling](https://vite.dev/guide/dep-pre-bundling), [performance](https://vite.dev/guide/performance), [CLI](https://vite.dev/guide/cli), [plugin API](https://vite.dev/guide/api-plugin), [build guide](https://vite.dev/guide/build)
- Rolldown: [checks](https://rolldown.rs/options/checks), [experimental](https://rolldown.rs/options/experimental), [lazy barrel](https://rolldown.rs/in-depth/lazy-barrel-optimization), [hook filters](https://rolldown.rs/in-depth/why-plugin-hook-filter)
- Plugins: [plugin-react](https://github.com/vitejs/vite-plugin-react/tree/main/packages/plugin-react), [its CHANGELOG](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react/CHANGELOG.md), [plugin-react-swc](https://github.com/vitejs/vite-plugin-react/tree/main/packages/plugin-react-swc), [vite-plugin-inspect](https://github.com/antfu-collective/vite-plugin-inspect), [Sentry Vite upload](https://docs.sentry.io/platforms/javascript/sourcemaps/uploading/vite)
- Vitest: [config (reads vite.config, `VITEST`, mode)](https://vitest.dev/config/), [deps](https://vitest.dev/config/deps), [migration](https://vitest.dev/guide/migration)
- Local probes (2026-11-09): vite 8.3.7 and 7.3.8 dists and builds, Vitest 5.1.0 runs, as described above.
