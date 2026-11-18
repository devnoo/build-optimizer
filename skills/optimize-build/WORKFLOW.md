# Investigation workflow

Run with the Workflow tool. Pass the script inline and the hotspots from step 3 as `args`:

```json
{
  "skillDir": "<absolute path of this skill>",
  "repoDir": "<absolute path of the repo>",
  "budgetFile": "<absolute path of the time-budget file from step 2>",
  "stack": ["vitest", "turbo", "docker", "go"],
  "scratchDir": "<absolute dir for skeptics' scratch copies>",
  "hotspots": [
    { "id": "h1", "lane": "test", "job": "ci / test", "step": "pnpm vitest run",
      "medianSec": 412, "p90Sec": 470, "cpShare": 0.55,
      "evidence": "https://github.com/o/r/actions/runs/123", "slowestTests": ["src/a.test.tsx 38s", "..."] }
  ]
}
```

`stack` = the keys from `scripts/detect-stack.sh` whose reference column is not `-`.

`repoDir` must be a checkout of exactly the ref you measured (e.g. `git worktree add --detach <dir> origin/main`
with dependencies installed). Investigators only read it. Skeptics edit config to measure a fix, so each
works in its own APFS/reflink copy of `repoDir` under `scratchDir` — not in `isolation: 'worktree'`, which
copies the *session's* HEAD and can be far behind the ref you measured. `budgetFile` is absolute because
it lives in the user's tree, not in `repoDir`.

```js
export const meta = {
  name: 'optimize-build-investigate',
  description: 'Audit each build hotspot plus cache and waste audits, then try to refute every finding',
  phases: [
    { title: 'Investigate', detail: 'one agent per hotspot + cache + waste audit' },
    { title: 'Refute', detail: 'one skeptic per item, measures in a scratch copy' },
  ],
}

const { skillDir, repoDir, budgetFile, scratchDir, hotspots, stack = [] } = args
const REF = f => `${skillDir}/references/${f}`
const JS_RUNNERS = ['vitest', 'jest', 'playwright']
const REFS = {
  // test-environment.md covers JS/TS runners only
  test: [REF('test-parallelism.md'), ...(JS_RUNNERS.some(k => stack.includes(k)) ? [REF('test-environment.md')] : [])],
  install: [REF('build-steps.md'), REF('ci-github-caching.md')],
  'typecheck-lint': [REF('build-steps.md')],
  build: [REF('build-steps.md')],
  docker: [REF('build-steps.md'), REF('ci-github-caching.md')],
  topology: [REF('build-steps.md'), REF('ci-github-timings.md')],
  cache: [REF('ci-github-caching.md')],
  waste: [REF('build-steps.md'), REF('ci-github-timings.md')],
}

// Stack references a lane may load — intersected with what detect-stack.sh found (keys whose
// stack file exists). The cache audit reads every detected stack file: each one lists its cache paths.
// go, rust, python, gradle and maven are whole-ecosystem files: each lane reads the checks that name its step.
const LANE_STACK = {
  test: ['vitest', 'jest', 'playwright', 'vite', 'go', 'rust', 'python', 'jvm', 'gradle', 'maven'],
  install: ['node-pm', 'turbo', 'nx', 'go', 'rust', 'python', 'gradle', 'maven'],
  'typecheck-lint': ['typescript', 'lint', 'turbo', 'nx', 'go', 'rust', 'python', 'gradle', 'maven'],
  build: ['vite', 'nextjs', 'turbo', 'nx', 'go', 'rust', 'gradle', 'maven'],
  docker: ['docker', 'rust', 'python', 'maven'],
  topology: ['turbo', 'nx', 'gradle', 'maven'],
  waste: ['turbo', 'nx'],
  cache: stack,
}
const refsFor = lane => [
  ...(REFS[lane] || REFS.topology),
  ...(LANE_STACK[lane] || []).filter(k => stack.includes(k)).map(k => REF(`stack/${k}.md`)),
]

const LANE_ASK = {
  test: `Answer each, with evidence:
1. Parallelism: is it on and effective? Check runner config + CLI flags in the build files and CI YAML
   (runInBand, singleFork, workers: 1, fileParallelism: false, maxWorkers; go test -p 1; no pytest -n;
   forkCount / maxParallelForks = 1) against the runner's core count.
   First get the core count: standard private-repo GitHub runners have 2 vCPU, so worker tuning there
   gains ~nothing — the levers are a larger runner or sharding. Settings silently ignored after an upgrade
   (e.g. Vitest 4+ ignores poolOptions, Surefire 3.6 ignores perCoreThreadCount) count as findings.
   If it is off or limited: WHAT BLOCKS IT (shared DB, fixed ports, shared paths, global state,
   order dependence, env mutation, memory). Name the files. Give the remedy per blocker.
2. Compile vs run: how much of the step is building test binaries or classes, and how much is running
   tests? Split it with the stack reference's Measure commands. A compile-dominated step is a cache or
   build finding, not a test finding.
3. Startup cost paid per file, class or worker: test environment (jsdom, happy-dom, browser mode),
   application contexts, containers, database setup, JVM or process forks, heavy fixtures and setup files.
   JS/TS only: which files need no DOM and can run in a node project, and does CSS reach the DOM in tests
   (CSS plugins inherited from vite.config, CSS imports mapped to real files in Jest)? If no test asserts
   on styles, CSS processing is pure cost.
4. Import/transform/collection cost: the runner's duration breakdown, barrel files, heavy setup or
   conftest imports, transform choice, collection that walks too many directories.
5. Result reuse: does the runner have a result cache (go test, Gradle, Nx/Turbo, the Maven build cache),
   and do unchanged packages or modules hit it in CI? If not, what busts the key?
6. Sharding: would splitting this job across runners shorten the critical path after per-job setup cost?
   Can shards reuse one build (an artifact or archive) instead of each compiling?
7. Long-running tests: when a few tests hold a large share of the run time after 2 and 3 are accounted
   for, name each one, its seconds, and what you expect it spends them on (computing, or waiting on
   sleeps, I/O, locks, network). One finding per test, with the test id in the title.`,
  cache: `Audit every cache in every workflow, not only the hotspots: missing caches for install, tool
caches (tsbuildinfo, eslint, turbo/nx, next, playwright browsers, docker layers, Go build cache, Cargo
target, Gradle User Home, ~/.m2, uv/pip, mypy), built-in setup-* caches with no restore keys, mis-keyed caches
(always miss / always stale), caches saved from PR branches, caches whose restore costs more than rebuild,
eviction from the 10 GB limit. Use the CI logs for hit/miss and restore time, and the cache list API.`,
  waste: `Find runs, jobs and matrix legs that should not happen. Per workflow: concurrency group with
cancel-in-progress on PR refs; trigger scope (paths/paths-ignore, or a change-detection job gating heavy
jobs when event filters are too coarse); duplicate coverage across workflow files; matrix breadth per event
(full on release, one representative leg on ordinary PRs); write-back bots (formatters, autofix) that run
automatically instead of on a label (listen for labeled AND unlabeled) or workflow_dispatch.
Express savings as runner minutes/day using runs/day from the budget file.`,
  docker: `Check the Dockerfile and how CI builds it:
1. Layer order: manifests + install before COPY . . (a source change must not re-run install or the
   dependency compile). Prefer bind-mounting the manifest into the install RUN for read-only installs
   (npm ci, pip install -r, uv sync --frozen, go mod download). Compiled languages: is the dependency
   build its own layer (cargo-chef, mvn dependency:go-offline, go mod download + go build of deps)?
2. BuildKit cache mounts (RUN --mount=type=cache) for the package manager. On ephemeral CI runners they
   start empty unless persisted — check whether the CI persists them, and whether cache-from/cache-to
   (type=gha or registry, mode=max) is set at all.
3. .dockerignore exists and excludes .git, node_modules, build output; measure context size.
4. COPY --link for artifacts copied from build stages; multi-stage so the runtime stage skips build deps.
5. Does this image need building on every PR at all?
Use docker build --progress=plain to see which steps say CACHED.`,
}
const DEFAULT_ASK = `Find why this step takes its time and what the reference says good looks like. Check every
detection item in the reference that applies to this step.`

const FINDINGS = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: { type: 'object', properties: {
      title: { type: 'string' },
      evidence: { type: 'string', description: 'file:line, log line, run URL or command + output' },
      fix: { type: 'string', description: 'the concrete change' },
      savesSec: { type: 'number', description: 'estimated seconds saved per run on the critical path' },
      effort: { type: 'string', enum: ['S', 'M', 'L'] },
      risk: { type: 'string' },
      blockers: { type: 'string', description: 'what must change first, if anything' },
    }, required: ['title', 'evidence', 'fix', 'savesSec', 'effort', 'risk'] } },
  },
  required: ['findings'],
}

const VERDICTS = {
  type: 'object',
  properties: {
    verdicts: { type: 'array', items: { type: 'object', properties: {
      title: { type: 'string' },
      survives: { type: 'boolean' },
      reason: { type: 'string' },
      savesSec: { type: 'number', description: 'revised estimate' },
      measured: { type: 'string', description: 'before/after command + numbers, or "not measured"' },
    }, required: ['title', 'survives', 'reason', 'savesSec', 'measured'] } },
  },
  required: ['verdicts'],
}

const items = [
  ...hotspots,
  { id: 'cache', lane: 'cache', step: 'all caches in all workflows' },
  { id: 'waste', lane: 'waste', step: 'triggers, concurrency, duplicates, matrix in all workflows' },
]

const GUARDRAILS = `Kill a finding that: hides required validation (release, migration, schema, shared-library
checks); cuts parallelism or merges jobs so the critical path grows past 1.25x without the user preferring
cost; drops a matrix leg that has a documented version/platform commitment; mixes repo YAML with org/billing
settings (split it instead).`

const results = await pipeline(
  items,
  h => agent(`Repo: ${repoDir}. Time budget: ${budgetFile}.
Hotspot ${h.id} (${h.lane}): ${h.job || ''} › ${h.step}. Median ${h.medianSec ?? '?'}s, p90 ${h.p90Sec ?? '?'}s,
${h.cpShare != null ? Math.round(h.cpShare * 100) + '% of the critical path' : 'off the critical path'}.
Evidence: ${h.evidence || 'see budget file'}. ${h.slowestTests ? 'Slowest tests: ' + h.slowestTests.join('; ') : ''}
Read first: ${refsFor(h.lane).join(', ')}.
${LANE_ASK[h.lane] || DEFAULT_ASK}
Read-only: do not edit files. Every finding needs evidence and a seconds estimate tied to this hotspot's numbers.`,
    { label: `investigate:${h.id}:${h.lane}`, phase: 'Investigate', schema: FINDINGS }),
  (res, h) => (!res || !res.findings.length) ? { hotspot: h, findings: [], verdicts: [] } :
    agent(`Repo: ${repoDir}. You are a skeptic. Try to REFUTE each finding below for hotspot ${h.id} (${h.lane}, ${h.step}).
A finding dies if: the evidence does not show it, the fix breaks behaviour, the saving is off the critical
path, or the saving is smaller than its cost (e.g. per-job setup when sharding). Default to survives=false
if you cannot confirm it. ${GUARDRAILS}
When a fix is cheap to try (a config flag, one env override, one file), MEASURE in a scratch copy, never in
${repoDir}: \`cp -cR ${repoDir} ${scratchDir}/skeptic-${h.id} && rm -rf ${scratchDir}/skeptic-${h.id}/.git\`
(macOS APFS clone; on Linux use \`cp -a --reflink=auto\`). Removing .git detaches the copy from the real
repository whether it was a worktree or a clone. Start any service the step needs (e.g. your own
Postgres container on a free port) and stop it afterwards. Other skeptics share this machine, so compare
before vs after back-to-back with the same command (≥ 2 runs each, interleaved) and report the relative
change. Never push, commit, or touch CI settings.
A finding about one long-running test survives only with a profile: run that test alone in the scratch copy
with the stack reference's "Profile one slow test" section (JS/TS: test-environment.md §1), write the output
outside the copy, and put the top frames and their share of the test's time in \`measured\`.
Reference: ${refsFor(h.lane).join(', ')}.
FINDINGS:
${JSON.stringify(res.findings, null, 2)}`,
      { label: `refute:${h.id}`, phase: 'Refute', schema: VERDICTS })
      .then(v => ({ hotspot: h, findings: res.findings, verdicts: v ? v.verdicts : [] })),
)

const done = results.filter(Boolean)
const dropped = items.length - done.length
if (dropped) log(`${dropped} hotspot(s) returned nothing — report them as not investigated`)
return done
```

Merge each finding with its verdict by `title`. Report only survivors; list refuted ones in one line
each at the bottom of the budget file so the next run does not re-propose them.
