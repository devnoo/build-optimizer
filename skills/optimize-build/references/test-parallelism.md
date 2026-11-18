# Test parallelism: use the cores the job has, then shard

Use when: a test step is a measured hotspot and you need to know whether it runs serially, under-uses its cores, or should be sharded.
Runner specifics for Vitest, Jest and Playwright are in `stack/vitest.md`, `stack/jest.md` and `stack/playwright.md`. §8 has the worker settings for pytest-xdist, go test, Gradle, Surefire and JUnit; what else those suites pay for (compile, result caches, fixtures, contexts, containers) is in `stack/python.md`, `stack/go.md`, `stack/rust.md` and `stack/jvm.md`. JS environment cost (jsdom, browser mode) is in `test-environment.md`.

Versions checked 2026-11-18 with `gh release list -R <repo> -L 3`: Vitest 5.1.1 (4.1.12 still gets patches), Jest 30.5.2, Playwright 1.65.1, pytest-xdist 3.8.0, Gradle 9.9.1, Surefire 3.6.1, JUnit 6.1.3, libuv 1.53.0. Facts were checked on 2026-11-09 and re-verified on 2026-11-18; source links stay pinned to the tags they were read at. **Read the repo's lockfile versions first.** Several defaults below changed in the last two majors.

## 0. Decision flow and fix menu

1. **Cores** (§1.1). A private-repo standard runner has 2 vCPU, so Jest, Vitest and Playwright already pick **1 worker**. Config changes gain nothing there. The levers are a larger runner or sharding.
2. **Serialisers** (§1.2): config or CLI flags that force serial runs.
3. **Measured concurrency** (§1.3). Do not trust config alone.
4. If the run is serial or under-uses its cores, find the blocker (§5) and fix it behind a shuffle-and-repeat gate (§6).
5. Shard (§7) only after one job's cores are saturated.

| Fix | Precondition | Gain | Risk |
|---|---|---|---|
| Remove a whole-suite serialiser (`--runInBand`, `workers: 1`, `fileParallelism: false`, `go test -p 1`) | ≥3 vCPU, shared resources isolated (§5) | Upper bound ≈ worker count × on a CPU-bound test step (arithmetic). **0 on 2 vCPU** | Collisions on shared DB/ports/files. Gate with §6 |
| Explicit worker count = CPU quota in containers | Quota < host CPUs (§1.1) | Removes oversubscription timeouts and OOMs. Typical, unmeasured | None |
| Vitest pool/isolate/env change chosen by `vitest doctor` | Vitest ≥5.0, green baseline | Measured per suite. The docs' example shows −67% on one suite; that is not a typical figure ([CLI](https://vitest.dev/guide/cli#vitest-doctor)) | `isolate: false` leaks state; vm pools have cross-realm issues |
| Playwright `fullyParallel` + test locks | Locks need ≥1.63 | Better worker packing and shard balance. Typical, unmeasured | Hidden in-file order dependencies |
| Larger runner instead of shards | GitHub Team/Enterprise plan | Setup is not duplicated. Price per core is flat (§7) | Cost per minute |
| Shard across N jobs | Cores saturated, test step ≫ setup | ≤ N× on the test step, minus N × setup | Billing rounds each job up to a minute; imbalance |

## 1. Detection

### 1.1 Cores, and what each tool does with them
```bash
gh repo view --json visibility -q .visibility        # PUBLIC/PRIVATE changes runner size
grep -rhoE 'runs-on:.*' .github/workflows | sort | uniq -c
# one-off CI step (decisive, cheap):
nproc; node -p 'const os=require("os"); [os.availableParallelism(), os.cpus().length]'
cat /sys/fs/cgroup/cpu.max 2>/dev/null   # "max 100000" = no quota; "200000 100000" = 2 CPUs
python3 -c 'import psutil; print(psutil.cpu_count(False), psutil.cpu_count())' 2>/dev/null; lscpu | grep -i 'per core'
```
Standard GitHub-hosted runners ([docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)):

| Label | Public repo | Private repo |
|---|---|---|
| `ubuntu-latest`/`-24.04`/`-22.04`, `*-arm` | 4 vCPU, 16 GB | **2 vCPU, 8 GB** |
| `windows-latest`, `windows-11-arm` | 4 vCPU, 16 GB | 2 vCPU, 8 GB |
| `macos-latest`/`-15`/`-26` (M1) | 3 vCPU, 7 GB | 3 vCPU, 7 GB |
| `macos-15-intel` | 4 vCPU, 14 GB | 4 vCPU, 14 GB |
| `ubuntu-slim` | 1 vCPU, 5 GB | 1 vCPU, 5 GB |

Default workers (n = CPUs as the tool counts them):

| Tool | Default, non-watch (watch) | n=2 | n=3 | n=4 | Source |
|---|---|---|---|---|---|
| Vitest 4/5 | `max(n−1,1)` (`max(⌊n/2⌋,1)`) | 1 | 2 | 3 | [workers.ts](https://github.com/vitest-dev/vitest/blob/v5.1.0/packages/vitest/src/utils/workers.ts). The docs' "all available parallelism" is imprecise |
| Jest ≥29.4 | `max(n−1,1)` (`max(⌊n/2⌋,1)`) | 1, **in band** | 2 | 3 | [getMaxWorkers.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-config/src/getMaxWorkers.ts) |
| Playwright | `max(1, ⌊cpus × 50%⌋)` | 1 | 1 | 2 | [config.ts](https://github.com/microsoft/playwright/blob/v1.65.0/packages/playwright/src/common/config.ts) |
| pytest-xdist `-n auto` | physical cores with `psutil`, else `len(sched_getaffinity)` | check | check | check | [plugin.py](https://github.com/pytest-dev/pytest-xdist/blob/v3.8.0/src/xdist/plugin.py) |
| `go test` | `-p` and `-parallel` = GOMAXPROCS | 2 | 3 | 4 | [cmd/go](https://pkg.go.dev/cmd/go) |
| Gradle `Test` | `maxParallelForks = 1` | 1 | 1 | 1 | [Test DSL](https://docs.gradle.org/current/dsl/org.gradle.api.tasks.testing.Test.html) |
| Surefire | `forkCount=1`, `reuseForks=true` | 1 | 1 | 1 | [fork options](https://maven.apache.org/surefire/maven-surefire-plugin/examples/fork-options-and-parallel-execution.html) |

- **Containers (k8s/ARC runners, `docker --cpus`).** Vitest and Jest count with `os.availableParallelism()`, which wraps libuv. libuv has honoured cgroup CPU quotas since **1.49.0** ([PR #4278](https://github.com/libuv/libuv/pull/4278), fixing [#4146](https://github.com/libuv/libuv/issues/4146) "does not handle container cpu limits"). Node bundles it from **22.12 / 23.1**; Node 20 never got it ([CHANGELOG_V22](https://github.com/nodejs/node/blob/main/doc/changelogs/CHANGELOG_V22.md)). Quotas below 1 CPU are handled from libuv 1.52 (Node 24.16).
- Playwright under a CPU quota (`os.cpus().length` vs `os.availableParallelism()`): see [stack/playwright.md](stack/playwright.md) check 2.
- `nproc` ignores cgroup quotas before coreutils 9.8 ([NEWS](https://github.com/coreutils/coreutils/blob/master/NEWS)), and Ubuntu 24.04 ships an older version, so read `cpu.max`. Go ≥1.25 sets GOMAXPROCS from the cgroup CPU limit ([Go 1.25](https://go.dev/doc/go1.25#container-aware-gomaxprocs)).
- **Fix:** in any container with a quota, pass an explicit worker count equal to the quota.
- **xdist on 2-vCPU VMs:** if `lscpu` shows 2 threads per core, psutil may report 1 physical core, giving 1 worker. This is unverified on GitHub runners: run the psutil one-liner. Fix with `-n logical`, `-n 2`, or `PYTEST_XDIST_AUTO_NUM_WORKERS`.
- **Percentages:** Vitest clamps the result to [1, n]. Jest treats only 1–100% as a percentage, so **`"200%"` is parsed as the integer 200** (getMaxWorkers.ts above). Playwright floors `cpus × p` with no cap, so `200%` works. Use plain numbers for Jest and Vitest.
- Jest's automatic in-band fallback: see [stack/jest.md](stack/jest.md) check 2.

### 1.2 Grep for serialisers (configs, package.json, CI YAML, Makefiles)
```bash
rg -n --hidden -g '!node_modules' -g '!.git' -f - . <<'EOF'
--runInBand
\bjest\b.*\s-i\b
--detectOpenHandles
--no-file-parallelism
fileParallelism["']?\s*[:=]\s*false
single(Fork|Thread)|poolOptions|minWorkers|max(Threads|Forks)|VITEST_MAX_(THREADS|FORKS)
max(Workers|Threads|Forks)["']?\s*[:=]\s*["']?1\b
\bworkers["']?\s*:\s*(1\b|process\.env\.CI\s*\?\s*1\b)
(--workers|--maxWorkers|-w)[= ]1\b
mode:\s*["']serial
fullyParallel["']?\s*:\s*false
\bgo test\b.*\s-p[= ]?1\b
-parallel[= ]1\b
-p no:xdist|-n ?0\b
maxParallelForks|forkEvery|forkCount|reuseForks|perCoreThreadCount|useUnlimitedThreads
junit\.jupiter\.execution\.parallel
EOF
```
What each hit means:
- Runner hits: Jest `--runInBand`/`-i`/`--detectOpenHandles` → [stack/jest.md](stack/jest.md) check 1; Vitest leftover v3 pool options and `fileParallelism: false` → [stack/vitest.md](stack/vitest.md) checks 1–2; Playwright `workers: process.env.CI ? 1 : undefined` → [stack/playwright.md](stack/playwright.md) check 1.
- `go test -p 1` usually means packages share a DB. A missing `maxParallelForks`/`forkCount` means 1 JVM fork. `perCoreThreadCount`/`useUnlimitedThreads` are **ignored since Surefire 3.6.0** (§8).
- No hits does not prove parallelism. Check §1.1 (1 worker on 2 vCPU) and §1.3.

### 1.3 Measure effective concurrency
- **CPU ratio:** GNU `/usr/bin/time -v <test cmd>` (the `time` package is in the ubuntu-24.04 image: [toolset](https://github.com/actions/runner-images/blob/main/images/ubuntu/toolsets/toolset-2404.json)). Read "Percent of CPU this job got" = (user+sys)/elapsed ([time(1)](https://man7.org/linux/man-pages/man1/time.1.html)). About 100% means one core; ≥250% on 4 vCPU means parallel. The figure includes children that exited and were waited for, including grandchildren whose parents waited ([getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html)). That should cover fork workers, but it has not been checked per runner. It **misses** work done inside `docker run`/compose containers. Bash `time` works too: compute (user+sys)/real.
- **Peak memory:** "Maximum resident set size" is the **largest single process**, not the sum over the tree (getrusage(2)). Treat it as roughly the per-worker peak.
- **Per-file overlap:** both `jest --json --outputFile=r.json` and `vitest run --reporter=json --outputFile=r.json` emit `testResults[].startTime/endTime`. In Vitest 5, `--outputFile` still wins. Without it, json now goes to `.vitest/json/output.json`, not stdout ([v5 migration](https://vitest.dev/guide/migration)).
```bash
jq '([.testResults[] | .endTime - .startTime] | add) as $busy
  | (([.testResults[].endTime] | max) - ([.testResults[].startTime] | min)) as $wall
  | {busy_s: ($busy/1000), wall_s: ($wall/1000), avg_concurrency: ($busy/$wall)}' r.json
```
  `avg_concurrency` ≈ 1 means serial. Good is ≥0.7 × workers (heuristic, not from a source). A long tail at the end means one big file dominates: split it. Vitest's span runs from the first test start to the last test end, so it **excludes import and environment time** ([json.ts](https://github.com/vitest-dev/vitest/blob/v5.1.0/packages/vitest/src/node/reporters/json.ts)) and undercounts busy time. Jest uses per-file `perfStats` ([formatTestResults.ts](https://github.com/jestjs/jest/blob/v30.5.2/packages/jest-test-result/src/formatTestResults.ts)).
- Runner log signals (Playwright `using M worker(s)`, Vitest `Duration` breakdown and hints): see [stack/playwright.md](stack/playwright.md) and [stack/vitest.md](stack/vitest.md) (Measure).
- **Monorepo nesting:** turbo runs 10 tasks at once by default ([turbo run](https://turborepo.dev/docs/reference/run)) and Nx runs 3 ([nx](https://nx.dev/docs/reference/nx-commands)). Each task's Vitest or Jest then starts n−1 workers of its own, which oversubscribes the CPU, inflates timeouts and causes OOMs. Cap one layer, e.g. `--concurrency=1` for test tasks or `--maxWorkers=2` per package.

## 2–4. Runner specifics (Vitest, Jest, Playwright)

- Vitest (version changes, `vitest doctor`, pools, `isolate`, in-file concurrency, worker count, results cache and ordering, `--shard`): see [stack/vitest.md](stack/vitest.md).
- Jest (version notes, `--runInBand`, `workerIdleMemoryLimit`, `test.concurrent`, `--shard`, `--randomize`, `JEST_WORKER_ID`): see [stack/jest.md](stack/jest.md).
- Playwright (defaults, `fullyParallel`, test locks, worker IDs, sharding and blob merge, per-worker browser memory): see [stack/playwright.md](stack/playwright.md).

## 5. Blockers and remedies

Rule of thumb: with default per-file isolation (Vitest, Jest, Playwright), **cross-file blockers are external**: DB, ports, filesystem, services, a shared app server. Module state, env and clock only block `isolate: false`, in-file concurrency, Go `t.Parallel`, and in-process JVM threads.

| Blocker | Symptom | Remedy |
|---|---|---|
| Shared database | Unique-key violations, "row not found", counts off by N | One DB or schema per worker, keyed on `VITEST_POOL_ID` / `JEST_WORKER_ID` / `TEST_PARALLEL_INDEX` / `PYTEST_XDIST_WORKER` / `${surefire.forkNumber}`. Clone a migrated template with `CREATE DATABASE x TEMPLATE tpl`; this fails if any other session is connected to the template ([PG](https://www.postgresql.org/docs/current/sql-createdatabase.html)). Or roll back a transaction per test, which works only when the code under test uses the test's connection, so **not** for E2E against a server |
| Container per test file | Slow start, Docker OOM | One Testcontainers instance in global setup, one DB per worker inside it. Pass the URL with Vitest `project.provide()`/`inject()` ([globalSetup](https://vitest.dev/config/globalsetup)). Testcontainers binds random host ports ([docs](https://node.testcontainers.org/features/containers/)) |
| Fixed ports | `EADDRINUSE` | `listen(0)` and read `server.address().port` ([net](https://nodejs.org/api/net.html)), or `basePort + workerId` |
| Shared FS paths | ENOENT/EEXIST, corrupted fixtures | `fs.mkdtemp()` per test, Playwright `testInfo.outputPath()`, pytest `tmp_path`, Go `t.TempDir()`, JUnit `@TempDir` |
| Module state / singletons | Passes alone, fails in the suite | Keep `isolate: true` for those files (their own project), or reset the state in `afterEach` |
| Order dependence | Fails only with some seeds | Shuffle (§6) and fix the leak. Never pin the order |
| Env var / cwd mutation | Config-dependent flakes | Vitest `vi.stubEnv` + `unstubEnvs: true`. Go `t.Setenv`/`t.Chdir` **panic** in parallel tests ([testing](https://pkg.go.dev/testing#T.Setenv)). JUnit `@ResourceLock(Resources.SYSTEM_PROPERTIES)` |
| Clock / fake timers | Timeouts under concurrency | Fake timers patch the worker's globals, so don't mix them with in-file `concurrent`. Go 1.25 `testing/synctest` gives each test a bubble with virtual time. JUnit has `Resources.TIME_ZONE`/`LOCALE` locks |
| External services / rate limits | 429s, sandbox-account collisions | Mock at the network edge. Playwright `lock` (1.63+). Otherwise per-worker accounts or the serial lane |
| Memory | Exit 137, `heap out of memory`, Jest "A worker process has failed to exit gracefully" | Workers × per-worker peak RSS < ~75% of RAM (heuristic). Lower the worker count; use Jest `workerIdleMemoryLimit`; use Vitest `vmMemoryLimit` and top-level `execArgv: ['--max-old-space-size=…']` (4.0+) |
| CPU starvation | Timeouts, not assertion errors, only in parallel | Workers ≤ cores (or quota). Reproduce by oversubscribing: `--maxWorkers=$(( $(nproc)*2 ))` (a number) or Playwright `--workers=200%`, with `--repeats`/`--repeat-each` |

Per-worker DB sketch (pin `maxWorkers` explicitly so global setup knows N):
```ts
// global-setup.ts: runs once, before workers. Vitest VITEST_POOL_ID and Jest JEST_WORKER_ID are 1..maxWorkers
// (Vitest 4.1/5.1 pool.ts assigns i+1; Vitest ≤3 unverified, so create 0..N there). VITEST_WORKER_ID is a
// different, ever-increasing id: don't key on it.
for (let i = 1; i <= MAX_WORKERS; i++) await admin.query(`CREATE DATABASE app_test_${i} TEMPLATE app_tpl`)
// setup file: runs in the worker before each test file and before app code is imported
process.env.DATABASE_URL = `postgres://…/app_test_${process.env.VITEST_POOL_ID ?? process.env.JEST_WORKER_ID}`
```
For E2E against one shared app server, a DB per worker does not help. Isolate by **data** instead: a per-worker tenant or user from a worker-scoped fixture keyed on `parallelIndex`.

## 6. Enabling safely: shuffle, repeat, quarantine

1. Get a green baseline in the current mode and save the per-file durations (§1.3 JSON).
2. Switch to parallel. Run K = 5–10 times with **random order and recorded seeds**:
```bash
s=$RANDOM; npx vitest run --sequence.shuffle.files --sequence.shuffle.tests --sequence.seed=$s || echo "vitest $s" >>flaky.txt
s=$RANDOM; npx jest --ci --randomize --seed=$s || echo "jest $s" >>flaky.txt   # ≥29.5; within-file only
npx playwright test --shuffle --repeat-each=3   # ≥1.64; prints "shuffle seed N", rerun with --shuffle N
pytest -n auto                                  # pytest-randomly (installed) shuffles by default, prints "Using --randomly-seed=N"; rerun with --randomly-seed=last
go test -shuffle=on -count=3 ./...              # prints the -test.shuffle seed; bypasses the test cache
```
   Vitest ≥5 also has `--repeats=N` ([repeats](https://vitest.dev/config/repeats)). Before Vitest 5.1.1 (4.1.12 included) the same `--sequence.seed` does not reproduce the shuffled file order, because the glob order varies between runs ([#11340](https://github.com/vitest-dev/vitest/issues/11340), fixed in 5.1.1 by [#11926](https://github.com/vitest-dev/vitest/pull/11926)); a seed recorded on ≤5.1.0 also gives a different order on 5.1.1. JUnit: set `junit.jupiter.testclass.order.default=org.junit.jupiter.api.ClassOrderer$Random` and `junit.jupiter.testmethod.order.default=org.junit.jupiter.api.MethodOrderer$Random` ([order](https://docs.junit.org/6.1.3/writing-tests/test-execution-order.html)).
3. For each failing seed, rerun that seed, then run the failing file **alone**. If it passes alone, the cause is shared state. If it fails alone, it is an ordinary flake.
4. **Quarantine without blocking the rest:** move offenders to a serial lane and keep everything else parallel. Record each one with an owner and a reason.
   Vitest serial lane (`projects` + `groupOrder`, and the inherited-`include` pitfall): see [stack/vitest.md](stack/vitest.md) check 2.
   Other runners. Jest: two invocations, `jest --selectProjects unit` then `jest --selectProjects db --runInBand`. Playwright: `{ lock: 'db' }` or a project with `workers: 1`. pytest: `@pytest.mark.xdist_group("db")` + `--dist loadgroup`, which runs that group in one worker but still alongside other workers.
5. Gate the merge on N green CI runs and watch the flake rate for a week. Keep the serial lane under ~10% of test runtime (heuristic). If it grows, fix root causes.

## 7. Sharding across CI jobs

- **Cost model:** per-job time ≈ fixed setup (checkout, install, build, browser download) + test time / N × imbalance, plus a merge job. GitHub **rounds each job up to a whole minute**. Linux x64 prices per minute: 2-core $0.006, 4-core $0.012, 8-core $0.022, 16-core $0.042; arm64 2-core $0.005 ([pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)). That works out to $0.0030 → $0.0026 per core-minute, flat or slightly falling. Larger runners need GitHub Team or Enterprise Cloud. Standard runners on public repos are free.
- **Caps:** concurrent jobs 20 (Free), 40 (Pro), 60 (Team), 500 (Enterprise). A matrix allows ≤256 jobs ([limits](https://docs.github.com/en/actions/reference/limits)).
- **When sharding pays** (heuristic): (a) the in-job workers already saturate the cores (§1.3); (b) the test step is ≥3× per-job setup; (c) setup is cached. Because per-core price is flat, on private repos a **larger runner** often beats N shards: setup is not duplicated. The exception is Vitest at high core counts, where the single Vite server becomes the bottleneck ([stack/vitest.md](stack/vitest.md) check 3).
- **Balance:** Vitest and Jest shard by **file count** (path hash). Playwright with `fullyParallel` shards by **test count**. None of them use durations. Measure the per-shard test step:
```bash
gh api "repos/{owner}/{repo}/actions/runs/$RUN/jobs" --paginate \
  --jq '.jobs[] | {name, steps: [.steps[] | select(.name|test("test";"i")) | {name, started_at, completed_at}]}'
```
  If max/mean > ~1.3 (heuristic), rebalance. Options: split giant files; enable `fullyParallel` (Playwright); or write a duration-aware `shard()` (Jest `testSequencer`, Vitest `sequence.sequencer`) that does greedy longest-first bin packing over the last JSON report. Python: pytest-split `--store-durations`, then `--splits N --group i --splitting-algorithm least_duration`. The default `duration_based_chunks` is incompatible with order-randomizing plugins ([pytest-split](https://github.com/jerry-git/pytest-split)).
- **Merging:** Vitest: `--reporter=blob --shard=i/N [--coverage]`, upload `.vitest` (v5; `.vitest-reports` in v4) with `include-hidden-files: true`, then `vitest --merge-reports [--coverage]` ([perf guide](https://vitest.dev/guide/improving-performance#sharding), [features](https://vitest.dev/guide/features#sharding)). Playwright: blob reports, then `merge-reports`. Jest: merge JUnit XML and coverage yourself. Set `strategy.fail-fast: false` so one red shard does not cancel the others, and give the merge job `if: ${{ !cancelled() }}`.

## 8. Other ecosystems (short)

**pytest-xdist 3.8** ([distribution](https://pytest-xdist.readthedocs.io/en/stable/distribution.html), [how-to](https://pytest-xdist.readthedocs.io/en/stable/how-to.html))
- Detect: no `-n` in `addopts` or CI, or `-p no:xdist`, or `-n 0`. `-n auto` counts physical cores when psutil is installed (§1.1). `-n logical` needs psutil in 3.8. Cap with `--maxprocesses`.
- `--dist load` is the default. `worksteal` handles uneven durations better. `loadgroup` + `xdist_group` pins a resource to one worker.
- Worker identity: the `worker_id` fixture (`gw0`…, or `master` without xdist), `PYTEST_XDIST_WORKER`, and `PYTEST_XDIST_WORKER_COUNT`. Session fixtures run **once per worker**; use a `FileLock` to run one once overall. pytest-django suffixes the test DB per xdist worker ([pytest-django](https://pytest-django.readthedocs.io/en/latest/database.html)).

**go test** ([cmd/go](https://pkg.go.dev/cmd/go))
- Packages run in parallel up to `-p`. Inside a package, only `t.Parallel()` tests run concurrently, up to `-parallel`. Both default to GOMAXPROCS.
- `-p 1` usually papers over a shared DB: give each package or test its own DB. golangci-lint `paralleltest` flags missing `t.Parallel()`, and `tparallel` flags inappropriate use ([linters](https://golangci-lint.run/docs/linters/)).
- The test cache often beats parallelism. It works only in package-list mode with cacheable flags (`-run`, `-short`, `-v`, `-parallel`, …). `-count=1`, `-shuffle` or any other flag disables it.

**JVM**
- Gradle 9.9: set `maxParallelForks` (default 1). It cannot exceed `--max-workers`; the [perf guide](https://docs.gradle.org/current/userguide/performance.html) shows `availableProcessors()/2`. Keep `forkEvery = 0`: a value of 1 forks a JVM per class, which the DSL docs call "very expensive". `org.gradle.parallel=true` parallelises tasks across projects.
- Surefire 3.6.x: `forkCount=1C` (multiplied by cores) with `reuseForks=true`. Put `${surefire.forkNumber}` (1..forkCount × `-T`) in the DB schema or working directory. **Since 3.6.0 all tests run on the JUnit Platform.** Only JUnit 4 `parallel=classes|methods|classesAndMethods` + `threadCount` and TestNG `parallel` still work. Suite-level values, `perCoreThreadCount`, `useUnlimitedThreads` and `threadCountSuites` are ignored. JUnit 5/6 use `junit.jupiter.execution.parallel.*` ([Surefire](https://maven.apache.org/surefire/maven-surefire-plugin/examples/fork-options-and-parallel-execution.html)).
- JUnit 6.1: parallel execution is **off** by default. When enabled, nodes default to `same_thread`. The safest first step is `parallel.enabled=true`, `mode.default=same_thread`, `mode.classes.default=concurrent`. Use `@Isolated` and `@ResourceLock` for shared state. Default strategy: `dynamic`, factor 1 → one thread per core ([parallel](https://docs.junit.org/6.1.3/writing-tests/parallel-execution.html)).

## 9. Anti-patterns

- `--runInBand` / `workers: 1` / `-p 1` on the **whole** suite because a few tests share a DB. Isolate those few (§5, §6).
- Vitest traps (leftover `poolOptions` after a 3→4+ upgrade, keying resources on `VITEST_WORKER_ID`): see [stack/vitest.md](stack/vitest.md) checks 1–2.
- `maxWorkers: '100%'` everywhere. Jest and Vitest default to n−1 because the main process needs a core, and in Vitest it also runs the Vite server. Jest `'200%'` means 200 workers.
- Trusting `nproc` or Playwright's 50% inside quota-limited containers (§1.1).
- Sharding a 2-minute suite into 8 jobs: each job pays setup plus up to a minute of billing rounding.
- Shuffle runs that never record the seed, so an order-dependent failure cannot be reproduced.
- Treating parallel-only timeouts as "flaky, add retries". They usually mean CPU or memory oversubscription (§5, last rows).
- Expecting more workers to help on private 2-vCPU runners, where the tools already choose 1. The levers are a larger runner or sharding.
