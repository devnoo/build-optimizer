# typescript — optimize-build stack reference

Use when: detect-stack.sh reported `typescript`. Lanes: typecheck-lint, cache.

Checked on 2026-11-09 and re-verified on 2026-11-18. **(cited)** means a linked vendor number. **(local)** means a check run on 2026-11-09 against `typescript` 5.9.3, 6.0.2 and 7.0.2 (Apple silicon, synthetic projects), so re-measure on the repo. **(heuristic)** means typical but unmeasured. On npm, `typescript` is `latest` 7.0.2 (2026-07-08) and `beta` 7.1.0-beta (2026-10-20), with no 7.1 RC yet. The newest 6.x is 6.0.3, and `@typescript/typescript6` is 6.0.2; it ships only the `tsc6` bin. Run `npm view typescript dist-tags` first.

## Short version

- **Turn it on by default:** set `"incremental": true` and `"tsBuildInfoFile": ".cache/tsc/tsbuildinfo"`. Keep the file outside `node_modules` (see "Cache paths") and gitignore it. It works with `noEmit` on TS 4.0 and later.
- **Local and pre-commit:** warm runs recheck only what changed, often 2–5× faster (heuristic).
- **CI:** cache the buildinfo only when a cold check takes more than about 30s (heuristic). On small repos, restoring the cache can cost more time than it saves. For the cache key and paths, see C4 and "Cache paths".
- **Monorepo:** use project references with `tsc -b` (C5). Unchanged projects are skipped, so this gives the biggest gain.
- **Cheaper wins first:** `skipLibCheck: true` (C2) often saves more than incremental. TS 7 is 8–12× faster (C6), so the cache matters less outside big monorepos.
- **Phantom errors after a TS or dependency upgrade:** delete the buildinfo (heuristic). In CI, the TS version in the cache key already forces a full rebuild.

## Measure

```bash
grep -nE '"(typecheck|type-check|tsc|check-types)"\s*:' package.json */*/package.json
grep -rnE '"(incremental|composite|skipLibCheck|isolatedDeclarations|types|tsBuildInfoFile|references|stableTypeOrdering|libReplacement)"' --include='tsconfig*.json' . | grep -v node_modules
npm ls typescript @typescript/typescript6 @typescript/native-preview vue-tsc svelte-check 2>/dev/null
npx tsc -p tsconfig.json --noEmit --incremental false --extendedDiagnostics   # cold, single project
npx tsc -b tsconfig.json -f -v --extendedDiagnostics                          # cold, build mode: per project + "Aggregate …" lines
```
- **Measure cold.** With a warm `.tsbuildinfo`, `Check time` reads `0` (TS 7), and TS ≤6 leaves the line out (local). A composite project rejects `--incremental false` with TS6379, so use `tsc -b -f` for it.
- **Fields.** `Files`, `Lines`, `Instantiations`, `Memory used`, `Parse/Bind/Check/Emit time` and `Total time` (which is not the sum of the phases) ([perf wiki](https://github.com/microsoft/TypeScript/wiki/Performance)). TS ≤6 splits lines into `Lines of Library/Definitions/TypeScript`; a large Definitions share points to C1/C2. TS 7 prints a single `Lines` plus `Config time`, `BuildInfo read time` and `Changes compute time` (local).
- **Why a file is in the program.** Run `tsc --listFilesOnly | grep -c node_modules`. `tsc --explainFiles | grep -c "implicit type library"` > 0 means `@types` is auto-included (local, on 5.9.3 and 6.0.2).
- **Per-file and per-expression time.** `tsc -p <cfg> --generateTrace <dir> --incremental false` (or `-b -f`), TS ≥4.1. Open `trace*.json` in `about://tracing` and look at the `checkSourceFile` and `checkExpression` events. The files "can get big" ([tracing wiki](https://github.com/microsoft/TypeScript/wiki/Performance-Tracing)). `npm i --no-save @typescript/analyze-trace && npx analyze-trace <dir>` lists hot spots and duplicate packages; `--skipMillis` defaults to 100 and `--forceMillis` to 500 ([analyze-trace](https://github.com/microsoft/typescript-analyze-trace)). Layout: TS ≤6 writes `trace.json` + `types.json`, and with `-b` it adds `legend.json` and numbered files. TS 7.0.2 writes one `trace.json` plus `types_<checkerId>.json` per checker and a `legend.json` (local). analyze-trace's support for the TS 7 layout is unverified, so trace with `tsc6` if it fails.
- **CPU profile.** On TS ≤6, `--generateCpuProfile x.cpuprofile` writes a V8 profile that opens in DevTools. TS 7.0.2 accepts that flag but writes nothing (local); use `--pprofDir <dir>` instead, which writes `<pid>-cpuprofile.pb.gz` and `<pid>-memprofile.pb.gz` in pprof format (local). Viewing it with `go tool pprof -top` was not verified.
- **CI logs.** Each log line carries a timestamp (`ci-github-timings.md`). Add `-v` to `tsc -b` and diff consecutive `Building project '…'` lines to get time per project. `-v` also prints why each project rebuilt; see "Cache paths" for how to read those reasons.

## Checks

**C1 Auto-included `@types`**
- **Check:** `npm ls typescript` is below 6.0 with no `"types"` key, or `"types": ["*"]` on any version; `explainFiles` hits are > 0.
- **Good:** an explicit array. On 6.0+ the default is already `[]` ([types](https://www.typescriptlang.org/tsconfig/types.html)).
- **Fix:** `"types": ["node"]`, adding test globals only in the test tsconfig. `["*"]` restores the 5.9 behaviour (local; [TS 6.0](https://devblogs.microsoft.com/typescript/announcing-typescript-6-0/)).
- **Gain:** "improved their build time anywhere from 20-50% just by setting `types` appropriately" (cited, TS 6.0).
- **Risk:** errors such as "Cannot find name 'process'/'describe'". These are expected; add the package.

**C2 `skipLibCheck`**
- **Check:** it is absent or `false`.
- **Good:** `true`, which skips checking every `.d.ts` and is marked "Recommended" ([tsconfig](https://www.typescriptlang.org/tsconfig/#skipLibCheck)). `skipDefaultLibCheck` is deprecated; use `skipLibCheck`.
- **Gain:** "can save time … at the expense of type-system accuracy" (typical, unmeasured).
- **Risk:** it "can often hide misconfiguration and conflicts in `.d.ts` files" ([perf wiki](https://github.com/microsoft/TypeScript/wiki/Performance)).

**C3 Program scope**
- **Check:** `Files` is far above the source count, or `listFilesOnly` shows `dist/`, build output or generated folders.
- **Good:** "Specify only input folders". Without an `exclude` list, `node_modules` is excluded by default (perf wiki).
- **Fix:** tighten `include`.
- **Gain:** typical, unmeasured.
- **Risk:** files dropped from every check. Confirm that tests are still type-checked somewhere.

**C4 No incremental cache in CI**
- **Check:** the Measure grep finds no `incremental`/`composite`, or the workflow never restores the `.tsbuildinfo`.
- **Good:** `"incremental": true` (allowed with `noEmit` since [TS 4.0](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-0.html)), `"tsBuildInfoFile": ".cache/tsc/tsbuildinfo"`, and the file cached as described under "Cache paths".
- **Gain (local, on 6.0.2 and 7.0.2, with both `-p` and `-b`):** a buildinfo restored into a tree with fresh mtimes at a different absolute path gave `Check time 0`, and editing one file re-checked only part of the program. Net gain = cold check time − restore time; measure both.
- **Risk:** low for correctness, because the buildinfo stores a content hash (`version`) per file. A stale restore is only slower. Never use `assumeChangesOnlyAffectDirectDependencies` in a CI gate: it rechecks only changed files and their direct importers ([tsconfig](https://www.typescriptlang.org/tsconfig/#assumeChangesOnlyAffectDirectDependencies)).

**C5 Monorepo without project references**
- **Check:** several `tsc -p` calls over overlapping configs, or one huge project. Also check `grep -l '"references"' tsconfig*.json */*/tsconfig*.json`.
- **Good:** a solution `tsconfig.json` with `"files": []` and `references`; without `"files": []`, it "will cause double compilation". The leaves are `composite`, built with `tsc -b` ([handbook](https://www.typescriptlang.org/docs/handbook/project-references.html)). Aim for "evenly-sized projects"; "5-20 projects is an appropriate range" (perf wiki).
- **Fix:** a referenced project may not set `noEmit` (TS6310, local). Use `"emitDeclarationOnly": true, "outDir": "<repo>/.cache/tsc/<pkg>"`. Per-package turbo/nx `typecheck` tasks with a remote cache get a similar result; see those stack files.
- **Gain:** "greatly improve the speed of typechecking" (handbook; typical, unmeasured).
- **Risk:** under `composite`, every file must match `include`, `declaration` is forced on, and `rootDir` defaults to the config directory.

**C6 Still on tsc 5.x/6.x for the CI check**
- **Check:** run `npm ls typescript`, then list the TS API consumers that block 7.0:
  `jq -r 'select(.peerDependencies.typescript?)|"\(.name)\t\(.peerDependencies.typescript)"' node_modules/*/package.json node_modules/@*/*/package.json`
- **Good:** TS 7's `tsc` runs the check, and API consumers stay on 6.0 through the official aliases `"@typescript/native": "npm:typescript@^7.0.2"` and `"typescript": "npm:@typescript/typescript6@^6.0.2"`. With those, `npx tsc` runs 7.0 and imports of `typescript` get the 6.0 API ([TS 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)). There is no bin clash, because the 6 package ships only `tsc6`.
- **Fix:** first clear the 6.0 deprecations: run tsc 6 with no `ignoreDeprecations`. TS 7 rejects removed options even when `"ignoreDeprecations": "6.0"` is set (TS5102 `baseUrl`, TS5108 `moduleResolution=node10`; local).
- **Gain:** "typically… between 8x and 12x on full builds". Benchmarks run 7.7–11.9×, and up to 16.7× on vscode with `--checkers 8` (cited).
- **Risk:** 7.0 "does not ship with an API". `typescript@7.0.2` exports only `./unstable/*`, `./package.json` and a `.` stub that holds just `version` and `versionMajorMinor`. These blockers were checked on npm on 2026-11-09:
  - Peer range below 7: typescript-eslint 8.72.1 `>=4.8.4 <6.1.0`, ts-jest 29.4.15 `>=4.3 <7`, svelte-check 4.7.8 `^5||^6`, @astrojs/check 0.9.12 `^5||^6`, @angular/compiler-cli 22.2.5 `>=6.0 <6.1`, typedoc 0.28.20 up to `6.0.x`.
  - Need the API anyway: vue-tsc, MDX and Astro, which "will likely not yet be able to leverage TypeScript 7" (cited).
  - Error messages may print types differently from 6.0 ([typescript-go](https://github.com/microsoft/typescript-go)).
  - Don't run `tsc` and `vue-tsc` over the same files (heuristic).

**C7 TS 7 parallelism versus runner size**
- **Check:** look for `--checkers`, `--builders` or `--singleThreaded` in scripts, and note the runner's vCPU count and RAM.
- **Good:** `--checkers` (experimental, default 4) is no higher than the vCPU count. `--builders` sets how many `-b` projects build concurrently, and it multiplies with `--checkers`.
- **Fix:** on small runners, "you may want to decrease this number". `--singleThreaded` suits "very limited resources" (TS 7.0).
- **Gain:** see C6. A bigger runner pays off only if CPU stays saturated.
- **Risk:** higher values "come at the cost of increased memory usage" (TS 7.0). In 4-checker benchmarks, TS 7.0 used about 2–8 GiB per project (2,017–8,387 MiB) ([7.1 beta](https://devblogs.microsoft.com/typescript/announcing-typescript-7-1-beta/)), so watch for OOM on 8 GB runners.

**C8 Leftover migration flag**
- **Check:** `grep -rn stableTypeOrdering`.
- **Good:** the flag is absent.
- **Fix:** remove it. It is "only intended to help diagnose differences between 6.0 and 7.0".
- **Gain:** removes a slowdown of "up to 25%" (cited, TS 6.0).
- **Risk:** none.

**C9 `libReplacement` on 5.x**
- **Check:** TS 5.x (5.9.3 defaults it to `true`, local) with no `"libReplacement": false`.
- **Fix:** set it to `false`; the default is `false` in 6.0+. The option "previously incurred a large number of failed module resolutions for every run" (TS 6.0).
- **Gain:** typical, unmeasured.
- **Risk:** only matters if the repo uses `@typescript/lib-*` replacement packages.

**C10 `isolatedDeclarations` (5.5+)**
- **Check:** a library monorepo where downstream `tsc -b` projects wait on upstream `.d.ts` emit.
- **Good:** `isolatedDeclarations: true`, which requires `declaration` or `composite`. Emit `.d.ts` with `tsc --noCheck` (5.6+), which then needs only "quick syntactic transformations", and run the check separately in parallel with its own `--tsBuildInfoFile` ([5.5](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-5.html), [5.6](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-6.html)).
- **Gain:** no official number; turning it on alone "won't immediately bring about the potential benefits" (typical, unmeasured).
- **Risk:** every export needs an explicit annotation; adopt it "on a case-by-case basis". Computed properties are not supported yet.

**C11 Fail-fast build mode**
- **Check:** CI runs `tsc -b` on TS ≥5.6, which keeps building downstream projects after upstream errors.
- **Fix:** `--stopBuildOnErrors`. This is the real flag name; the 5.6 release notes misspell it as `--stopOnBuildErrors` (local, in `--help` for 5.9.3, 6.0.2 and 7.0.2).
- **Gain:** failing runs only (unmeasured).
- **Risk:** each run reports fewer errors.

## Cache paths

- **Where the buildinfo lands by default** ([tsBuildInfoFile](https://www.typescriptlang.org/tsconfig/tsBuildInfoFile.html)):
  - `rootDir` and `outDir` set: `<outDir>/<relative path from rootDir to config>/<config name>.tsbuildinfo`. With `rootDir: src` and `outDir: dist`, that is `./tsconfig.tsbuildinfo`.
  - Only `outDir` set: `<outDir>/<config name>.tsbuildinfo`.
  - Otherwise: next to the config.
  - Detect it through `"incremental"`/`"composite"`; `incremental` defaults to `true` under `composite`. With `tsc -b` on TS ≥5.6, a buildinfo is written for every project, even without either option (5.6 notes).
- **Trap: the TS 6.0 `rootDir` fix moves the default path.** 6.0 made `rootDir` default to the config directory. A 5.x repo with `outDir` but no `rootDir` keeps its buildinfo at `<outDir>/<config name>.tsbuildinfo`, but its emit layout changes and tsc reports TS5011; adding `"rootDir": "src"` to fix that moves the default buildinfo next to the config (local, 5.9.3, 6.0.2 and 7.0.2). Set `tsBuildInfoFile` explicitly to a path outside `node_modules`, because `npm ci` deletes `node_modules`.
- **Build mode: cache outputs with the buildinfo.** With `tsc -b`, cache the emitted outputs (`outDir`/`declarationDir`) together with the buildinfo. If only the buildinfo is restored, `-b` reports "up to date" and never re-emits the missing `.d.ts`, so the next downstream rebuild fails with TS6305 "Output file … has not been built from source file" (local, 7.0.2). A shared `.cache/tsc/<pkg>` (C5) covers both with one path, as long as `rootDir` is the config directory. With `rootDir: src` the default buildinfo lands one level up, at `.cache/tsc/tsconfig.tsbuildinfo` for every package, and `-b` fails with TS6377 (local, 6.0.2 and 7.0.2); set `tsBuildInfoFile` per package then.
- **Cache key.** Use `tsc-${{ runner.os }}-<TS version>-${{ hashFiles('<lockfile>', 'tsconfig*.json', 'packages/*/tsconfig*.json') }}-${{ github.sha }}`, with `restore-keys: tsc-${{ runner.os }}-<TS version>-`. Read the version from `node -p "require('typescript/package.json').version"`; this works on 7.0 because `./package.json` is exported. Compute the key before install, or list explicit paths, so `hashFiles` never walks `node_modules`. The version belongs in the key because buildinfo from another version forces a full rebuild: `-b -v` prints TS6381 "generated with version '6.0.2' that differs with current version '7.0.2'" (local).
- **Restore order.** Restore after checkout and before `tsc`. With the path outside `node_modules`, the order relative to install doesn't matter. If the buildinfo sits inside `node_modules`, restore it after install or move it. Save it only from the default branch (`ci-github-caching.md`).
- **Trap: tsc6 and tsc7 sharing one buildinfo.** If both run on the same config, each overwrites the other's buildinfo, and every run becomes a full check (local). Give one of them its own `--tsBuildInfoFile`. Do the same for a concurrent `--noCheck` emit and `--noEmit` check (5.6 notes).
- **Reading `tsc -b -v` after a restore.** In CI, the restored outputs are older than the freshly cloned inputs:
  - TS6350 "out of date because output … is older than input 'tsconfig.json'" followed by `Building project` still reuses the buildinfo: `Check time 0` on 7.0.2 and about 4× less total time on 6.0.2 (local). Judge a restore by `Check time`, not by the `-v` wording.
  - TS6400 "up to date but needs to update timestamps" means only the mtimes differed.
  - TS6351 means up to date. TS6354 means up to date with its dependencies' `.d.ts`.

## Version traps

- **Added:** `incremental` and `tsBuildInfoFile` in 3.4; `incremental` + `noEmit` allowed in 4.0; `--generateTrace` in 4.1; `isolatedDeclarations` in 5.5.
- **5.6:** `--noCheck` on the CLI. `-b` no longer stops at upstream errors and always writes `.tsbuildinfo`. The opt-out flag is `--stopBuildOnErrors`.
- **6.0 (2026-03-23), changed defaults:**
  - `types: []` (`["*"]` restores the old behaviour).
  - `strict: true`, `module: esnext`, and `target` = the current-year ES version.
  - `rootDir` = the config directory, which moves `outDir` layouts (TS5011); the default buildinfo path moves only when `rootDir` is then set explicitly (local).
  - `noUncheckedSideEffectImports: true` and `libReplacement: false`.
- **6.0, deprecated or removed:**
  - Deprecated: `target es5`, `downlevelIteration`, `moduleResolution node`/`node10`, `baseUrl`, `esModuleInterop`/`allowSyntheticDefaultImports false`, `alwaysStrict false`, and `assert` imports (TS2880). `"ignoreDeprecations": "6.0"` silences these. `module` used as `namespace` is a hard error (TS1540) that it does not silence (local, 6.0.2).
  - Also only deprecated in 6.0.2, although the post's text says "removed" (TS5101/TS5107, silenced by `ignoreDeprecations`; local): `moduleResolution classic`, `module amd|umd|system|none` and `outFile`. `no-default-lib` directives are no longer honoured and raise no error (local).
  - Passing CLI file paths while a tsconfig is present triggers "tsconfig.json is present but will not be loaded".
  - `--stableTypeOrdering` is a temporary flag (C8).
- **7.0 (2026-07-08, Go port, published as `typescript` with bin `tsc`):**
  - Every 6.0 deprecation is a hard error, and `ignoreDeprecations` does not help. CLI file paths with a tsconfig present need `--ignoreConfig`.
  - There is no API.
  - New flags: `--checkers` (default 4), `--builders` and `--singleThreaded`. `--watch` was rebuilt on a port of Parcel's watcher.
  - `--generateCpuProfile` produces no output; use `--pprofDir` (local).
  - Status in [typescript-go](https://github.com/microsoft/typescript-go): build mode, incremental, declaration emit and watch are "done"; LSP is "in progress"; the API is "not ready".
  - Before GA the preview shipped as `@typescript/native-preview` (bin `tsgo`; last published `7.0.0-dev.20260707.2`). Treat it as stale and move to `typescript@7`.
- **7.1 beta (2026-10-20):** adds an API (`typescript/sync`, `/async`, `/fs`, `/ast`) and `contentMappers` (Vue, Svelte, Astro, MDX, CSS Modules, Ember; these need `--runExternalCode`). It is 1.2–1.9× faster than 7.0 under `--noEmit` with 4 checkers, and uses 15.8–49.6% less memory (cited). The RC was announced for "in about a month". Install with `npm i -D typescript@beta`.

## Sources

- https://github.com/microsoft/TypeScript/wiki/Performance
- https://github.com/microsoft/TypeScript/wiki/Performance-Tracing
- https://github.com/microsoft/typescript-analyze-trace
- https://www.typescriptlang.org/tsconfig/ (#skipLibCheck, #incremental, #composite, #assumeChangesOnlyAffectDirectDependencies, #noCheck), plus the tsconfig pages [tsBuildInfoFile](https://www.typescriptlang.org/tsconfig/tsBuildInfoFile.html) and [types](https://www.typescriptlang.org/tsconfig/types.html)
- https://www.typescriptlang.org/docs/handbook/project-references.html
- Release notes: [4.0](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-0.html), [5.5](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-5.html), [5.6](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-6.html), [6.0](https://devblogs.microsoft.com/typescript/announcing-typescript-6-0/), [7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/), [7.1 beta](https://devblogs.microsoft.com/typescript/announcing-typescript-7-1-beta/)
- https://github.com/microsoft/typescript-go
- npm registry (`npm view <pkg> version peerDependencies dist-tags time`), queried 2026-11-09
