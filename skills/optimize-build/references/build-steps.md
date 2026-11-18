# Reference: build steps and pipeline topology

> **Use when** a measured hotspot is in the `install`, `typecheck-lint`, `build`, `docker` or `topology` lane, or while running the waste audit.
> **Skip** for test-runner hotspots (`test-*.md`) and cache-key problems (`ci-github-caching.md`).

Facts were checked on **2026-11-09** and re-verified on **2026-11-18** (links, quoted passages and the highest-impact claims), and each one names the version it applies to. **(cited)** means a vendor or maintainer number, linked; vendor benchmarks are not independent. **(heuristic)** means typical but unmeasured, so measure it on this repo before you claim a gain.

**Latest versions on 2026-11-18** (from `npm view <pkg> version` and `gh api repos/<o>/<r>/releases`): typescript 7.0.2 (7.1.0-beta, no 7.1 RC yet), @typescript/typescript6 6.0.2, eslint 10.15.0, typescript-eslint 8.73.0, prettier 3.10.1, @biomejs/biome 2.6.8, oxlint 1.94.0, vite 8.3.8, next 16.4.6, webpack 5.112.2, turbo 2.11.12, nx 24.0.6, npm 12.2.3, pnpm 12.21.0, bun 1.4.4, @playwright/test 1.65.1. Actions: `actions/checkout` v7.0.1, `actions/setup-node` v7.1.0, `actions/cache` v6.1.0, `docker/build-push-action` v7.4.0, `pnpm/setup` v3.2.0, `pnpm/action-setup` v6.1.1. Check the repo's versions before you apply anything below.

## 0. Ground rules

- §2–§5 and §7 detail Node and TypeScript. For Go, Rust, Python, Gradle and Maven the install, compile, lint and cache checks live in the stack file ([go](stack/go.md), [rust](stack/rust.md), [python](stack/python.md), [gradle](stack/gradle.md), [maven](stack/maven.md)). §1, §8 and §9 apply to every stack.
- Touch only the steps the timing data ranked. Re-measure on the **same runner label**, with at least 3 runs, and report cold-cache and warm-cache times separately.
- A faster pipeline that silently stops type-checking, linting or building something is a regression. If you move a check, say where it moved to.
- Report **wall-clock** (the critical path) separately from **billed minutes**. Fanning out improves the first and can make the second worse (§8).

## 1. Per-step breakdown (prerequisite for every section)

Full adapter: `ci-github-timings.md`. The quick version below was tested against the live API on 2026-11-08. Live responses return `...Z` without fractional seconds. The REST docs only say `date-time` ([jobs API](https://docs.github.com/en/rest/actions/workflow-jobs)), so the parser also handles fractions and `±hh:mm` offsets.
```bash
gh api "repos/$OWNER/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" --jq '
  def t: sub("\\.[0-9]+";"") as $s | if ($s|endswith("Z")) then $s|fromdateiso8601
    else ($s[0:19]+"Z"|fromdateiso8601) - (($s[19:20]+"1"|tonumber)*(($s[20:22]|tonumber)*3600+($s[23:25]|tonumber)*60)) end;
  .jobs[] | "\(.name)\tqueue=\((.started_at|t)-(.created_at|t))s\ttotal=\((.completed_at|t)-(.started_at|t))s\trunner=\(.labels|join(","))",
  (.steps[] | select(.started_at and .completed_at) | "   \((.completed_at|t)-(.started_at|t))s\t\(.name)")'
```
- Tag each step as **setup** (checkout, `setup-*`, cache restore, install, browser install) or **work**. Every job pays its setup cost again. When setup is ≥30–40% of a job, that job is a merge candidate (§8) (heuristic).
- Tool profilers (tsc diagnostics and traces, ESLint `TIMING`, `turbo --summarize`, the build-push-action summary, `next build` phase lines): see the Measure section of [stack/typescript.md](stack/typescript.md), [stack/lint.md](stack/lint.md), [stack/turbo.md](stack/turbo.md), [stack/docker.md](stack/docker.md) and [stack/nextjs.md](stack/nextjs.md).

## 2. Install

**Detect**
```bash
ls package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb 2>/dev/null
grep -nE 'npm (ci|install|i)\b|pnpm (i|install|fetch)|yarn( install)?\b|bun (ci|install)' .github/workflows/*.y*ml
grep -nE 'setup-node|pnpm/(action-)?setup|setup-bun|actions/cache|cache:|package-manager-cache' .github/workflows/*.y*ml
jq '{packageManager, devEngines, scripts: (.scripts|with_entries(select(.key|test("install|prepare"))))}' package.json
grep -rlE '"(puppeteer|playwright|@playwright/test|cypress|electron)"' --include=package.json . | grep -v node_modules
```
**Good state**: frozen install, the package store cached (not `node_modules`), no browser or binary downloads in jobs that don't use them, and monorepo jobs installing only their slice.

Package-manager specifics (`npm ci`, npm flags and npm 12 script approval, pnpm CI freeze and build settings, `bun ci`, setup-node and pnpm/setup store caching): see [stack/node-pm.md](stack/node-pm.md).

| Fix | Detail, gain and risk |
|---|---|
| Skip browser downloads | Puppeteer: `PUPPETEER_SKIP_DOWNLOAD=true` (or `PUPPETEER_CHROME_SKIP_DOWNLOAD`). The cache lives in `~/.cache/puppeteer` ([config](https://pptr.dev/api/puppeteer.configuration)). The `playwright` and `@playwright/test` packages ≥1.38 do not download during `npm install` (the `@playwright/browser-*` packages still do) ([v1.38.0](https://github.com/microsoft/playwright/releases/tag/v1.38.0)), so the cost is in `npx playwright install`. Run it only in E2E jobs, install only the browsers you use (`--with-deps chromium`), and add `--only-shell` for headless-only runs ([browsers](https://playwright.dev/docs/browsers)). |
| Monorepo slice | `pnpm install --filter <app>...` (the trailing `...` adds the package's dependencies) ([filtering](https://pnpm.io/filtering)). In Docker: `turbo prune <app> --docker` emits `json/`, `full/` and a pruned lockfile ([prune](https://turborepo.dev/docs/reference/prune)). Alternatively, `pnpm fetch` needs only the lockfile, then run `pnpm install -r --offline` ([fetch](https://pnpm.io/cli/fetch)). |
| Toolchain installers | `setup-*`, `jdx/mise-action` and asdf steps run in every job. Check that the pinned major is current and that its tool cache is on, then read the step's log for download lines. A stale major can cost tens of seconds per job (heuristic; one real repo measured 26 s from a mise-action upgrade). |

**Pitfalls**
- Tool caches **inside `node_modules`** (Prettier `node_modules/.cache/prettier`, webpack `node_modules/.cache/webpack`) are wiped by `npm ci`. webpack's docs say outright that `npm ci` "will prune cache files" ([webpack cache](https://webpack.js.org/configuration/cache/)). Move these caches to `.cache/…`, or restore them *after* install.
- Caching `node_modules` itself is only safe if the key includes OS, arch, Node major and the lockfile hash, and install is skipped on an exact hit. Native addons break across those dimensions.

## 3. Typecheck

**Facts**
- Bundlers don't typecheck. "Vite only performs transpilation on `.ts` files and does NOT perform type checking" ([Vite features](https://vite.dev/guide/features)). esbuild, SWC and Babel are the same.

Detect commands, tsconfig levers (`skipLibCheck`, `types`, incremental cache, project references, `isolatedDeclarations`), TS 6.0/7.0/7.1 changes and the vue-tsc/svelte-check/astro pitfalls: see [stack/typescript.md](stack/typescript.md). `next build`'s own type check, and keeping one check per program: see [stack/nextjs.md](stack/nextjs.md) check 4.

## 4. Lint / format

ESLint, typescript-eslint, Prettier, Oxlint and Biome (detect, `--cache`, `--concurrency`, `projectService`, slow plugins, changed-files lint): see [stack/lint.md](stack/lint.md).

## 5. Bundling

**Detect**
```bash
jq -r '.scripts.build, ((.dependencies//{})+(.devDependencies//{})|to_entries[]|select(.key|test("^(vite|rolldown-vite|next|webpack|rollup|esbuild|@swc/core|@vitejs/plugin-react.*|@rolldown/plugin-babel|babel-loader|swc-loader|esbuild-loader|terser|babel-plugin-react-compiler)$"))|"\(.key)@\(.value)")' package.json
ls .babelrc* babel.config.* 2>/dev/null
grep -nE 'sourcemap|productionBrowserSourceMaps|devtool|minify|reportCompressedSize|reactCompiler|turbopackFileSystemCache|cache:' vite.config.* next.config.* webpack.config.* 2>/dev/null
grep -nE 'next build( --webpack)?|\.next/cache' package.json .github/workflows/*.y*ml
```
- **Vite** (Rolldown in Vite 8, build options and minifier, `@vitejs/plugin-react` v6 and Babel): see [stack/vite.md](stack/vite.md) B1–B5 and T2.
- **Next.js** (Turbopack default, Babel and React Compiler cost, no lint in `next build` 16, the build FS cache): see [stack/nextjs.md](stack/nextjs.md) checks 1–3, 5–6.
- **webpack 5**: caching is **off by default in production mode**, so set `cache: { type: 'filesystem', buildDependencies: { config: [__filename] } }`. The default dir is `node_modules/.cache/webpack`. CI must run "in the same absolute path", because cache files store absolute paths ([webpack cache](https://webpack.js.org/configuration/cache/)). Replace `babel-loader` with `swc-loader`/`esbuild-loader`: SWC is "20x faster than Babel on a single thread" ([swc.rs](https://swc.rs/)). Precondition: no Babel-only plugins.
- **PR builds**: produce sourcemaps only in the build that uploads them, and don't minify bundles that only feed tests. Build only affected apps (§7). Skip Storybook and docs builds unless their paths changed (heuristic, gain unmeasured).

## 6. Docker

Detect, layer order, cache mounts, external layer cache, multi-stage, multi-arch, PR waste and small wins: see [stack/docker.md](stack/docker.md).

## 7. Monorepo task graph

**Detect**
```bash
ls turbo.json nx.json pnpm-workspace.yaml lerna.json 2>/dev/null
grep -nE 'turbo (run )?|nx (affected|run-many)|--filter|--affected|TURBO_(TOKEN|TEAM|SCM_BASE)|NX_(BASE|HEAD)|nx-set-shas|fetch-depth' .github/workflows/*.y*ml
jq '.tasks // .pipeline | map_values({outputs, inputs, env})' turbo.json   # fails on JSONC comments
```
- Turborepo (`--affected`, remote cache, `outputs`/`env` pitfalls, one turbo job instead of per-package jobs) and Nx (`nx affected` with `nx-set-shas`, lockfile-change scope): see [stack/turbo.md](stack/turbo.md) and [stack/nx.md](stack/nx.md).

## 8. Pipeline topology (GitHub Actions)

**Model**: wall-clock ≈ queue + the longest `needs:` chain of (setup + work). "GitHub rounds the minutes and partial minutes each job uses up to the nearest whole minute" ([pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)). So six 20 s jobs bill 6 min, while one 2 min job bills 2.

**Detect** (Ruby ships on GitHub's Ubuntu images and macOS; tested 2026-11-09)
```bash
ruby -ryaml -e 'Dir[".github/workflows/*.y*ml"].each{|f| (YAML.load_file(f)["jobs"]||{}).each{|k,v| puts [File.basename(f),k,"needs="+Array(v["needs"]).join(","),"on="+Array(v["runs-on"]).join(","),"timeout=#{v["timeout-minutes"]||"none"}","if=#{v["if"]}"].join("\t")}}'
grep -nE 'concurrency:|cancel-in-progress|paths(-ignore)?:|fetch-depth|merge_group|timeout-minutes|runs-on|matrix:' .github/workflows/*.y*ml
```

| Situation | Do |
|---|---|
| lint, typecheck, test and build run serially in one job, each ≥2× the job's setup time | Fan out into parallel jobs with **no** `needs` between them. Wall-clock ≈ max(work) + setup (heuristic). |
| Many jobs whose work is shorter than their setup | Merge them, or run them in one job via turbo/nx or `npm-run-all -p`. |
| `needs:` used only for ordering, with no artifact passed | Remove the edge. Each edge adds queue + setup to the critical path. |
| E2E or deploy needs the build output | Keep the `needs` and pass the artifact (or use turbo/remote cache) instead of rebuilding. |
| No `concurrency` | Add the block below. Don't cancel `main` deploys. |
| Workflow-level `paths:` on a **required** check | Skipped workflows leave checks "Pending" and block merging ([required checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)). Gate at **job** level and require a single always-run gate job. |
| `fetch-depth: 0` everywhere | Use it only where history is needed (affected, changed-files), and add `filter: blob:none`. The default is `1` ([checkout action.yml](https://github.com/actions/checkout/blob/main/action.yml)). |
| No `timeout-minutes` | The job default is **360** ([workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)). Set it to ~2–3× p95 so hung jobs stop billing (heuristic). |
| Merge queue in use | Add the `merge_group:` trigger, or required checks never report ([required checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)). |
| Full matrix on every PR | Run a reduced matrix on PRs and the full one on `main`/`merge_group` (heuristic). Risk: platform-specific bugs surface later. |

```yaml
concurrency:   # head_ref exists only on PRs; push runs fall back to the unique run_id
  group: ${{ github.workflow }}-${{ github.head_ref || github.run_id }}
  cancel-in-progress: true
```
Group names must be unique across workflows, or runs of different workflows cancel each other. `cancel-in-progress` also accepts an expression ([concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)).

```yaml
ci-ok:                       # the ONLY required check
  if: always()
  needs: [lint, typecheck, test, build]
  runs-on: ubuntu-slim       # 1 vCPU container, 15-min limit, $0.002/min
  steps:
    - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
      run: exit 1
```
Why: dependents of a failed job are skipped unless they use `always()` ([workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)), and a job skipped by a conditional "reports Success" ([required checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)). Without `always()` plus the explicit `exit 1`, a failure can merge as green.

**Path filters**: a workflow runs "if at least one path matches". A push with more than 1,000 commits **always** runs, and when a diff has more than 3,000 files, matches outside the first 3,000 do **not** trigger a run ([workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)). For job-level gating, use a small first job (`git diff` or `dorny/paths-filter` v4) whose outputs feed the `if:` of later jobs.

**Runners** (USD/min, [pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing); prices since 2026-01-01)

| Size | x64 | arm64 | arm64 saving |
|---|---|---|---|
| 1-core `ubuntu-slim` | 0.002 | – | – |
| 2-core standard (private repos) | 0.006 | 0.005 | 17% |
| 4-core | 0.012 | 0.008 | 33% |
| 8-core | 0.022 | 0.014 | 36% |
| 16-core | 0.042 | 0.026 | 38% |

- Standard runners: public repos get 4 vCPU/16 GB, private repos 2 vCPU/8 GB. The `ubuntu-24.04-arm` (and `-22.04`/`-26.04`) arm labels work in both ([runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)). arm64 preconditions: native deps, Docker base images and any downloaded CLIs all ship arm64.
- `ubuntu-slim` (GA 2026-01-22) is an unprivileged container with 1 CPU, 5 GB and a 15-minute job limit, meant for gates, labelers and light lint ([changelog](https://github.blog/changelog/2026-01-22-1-vcpu-linux-runner-now-generally-available-in-github-actions/), [runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
- Larger runners can draw from included usage only on Team and Enterprise Cloud, and public-repo usage is billed. They support custom images that "pre-install dependencies and reduce setup time" ([larger runners](https://docs.github.com/en/actions/concepts/runners/larger-runners)). Doubling cores doubles the price, so only upgrade when the bottleneck parallelises (tsc 7 `--checkers`, ESLint `--concurrency`, test workers, turbo, Rolldown). Check CPU use first (heuristic).
- Self-hosted: GitHub "postponed" the announced self-hosted billing change (originally 2026-03-01) and set no new date ([GitHub](https://github.com/resources/insights/2026-pricing-changes-for-github-actions)). The pricing page lists no self-hosted fee. The real costs are ops work and security risk on fork PRs.

**Actions versions**: `actions/checkout@v7`, `actions/setup-node@v7`, `actions/cache@v6`. The Node 24 majors need runner ≥2.327.1 ([cache](https://github.com/actions/cache), [setup-node](https://github.com/actions/setup-node)). The cache is 10 GB/repo with 7-day retention by default. Pro, Team and Enterprise accounts can raise it pay-as-you-go ([changelog](https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/)). Uploads are limited to 200/min/repo ([limits](https://docs.github.com/en/actions/reference/limits)), which a wide matrix can hit.

## 9. Quick triage

| Symptom in timings | First check | Typical fix |
|---|---|---|
| Install >60 s in every job (heuristic) | store cache, browser downloads, job count | cache the store, skip downloads, merge jobs |
| `tsc` >60 s | `--extendedDiagnostics` file count, `types`, `skipLibCheck` | `types`, `skipLibCheck`, tsbuildinfo cache, TS 7 |
| ESLint ≫ tsc | `TIMING=1 … -o /dev/null`, `parserOptions.project` | `projectService`, drop prettier/import rules, Oxlint pre-pass |
| `next build` / `vite build` slow | Babel config, `--webpack`, `reactCompiler`, `.next/cache` restore | Turbopack/Rolldown, restore the cache, no sourcemaps in PRs |
| Many short jobs | setup ratio (§1), billed vs wall-clock | merge jobs, one `turbo --affected` job, `ubuntu-slim` for gates |
| Runs pile up on PRs | `concurrency` | `cancel-in-progress` keyed on `head_ref` |
| `go test` never prints `(cached)` | `-count=1`, fresh mtimes on fixtures, frozen `GOCACHE` | [stack/go.md](stack/go.md) checks 1–2 |
| Registry crates recompile on a cache hit | features, profile or `RUSTFLAGS` differ between steps | [stack/rust.md](stack/rust.md) checks 2 and 4 |
| `pip install` or `uv sync` slow on every run | lockfile, cache contents, `Building wheel` lines | [stack/python.md](stack/python.md) checks 1–4 |
| Gradle summary shows `0 from cache` | `org.gradle.caching`, forcing flags, cache written only on main | [stack/gradle.md](stack/gradle.md) checks 2–3 |
| Maven compiles or tests twice per job | several `mvn` steps, no build cache extension | [stack/maven.md](stack/maven.md) checks 1 and 4 |

Docker step slow: see [stack/docker.md](stack/docker.md) (layer order, cache backend, QEMU).
