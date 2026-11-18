---
name: optimize-build
description: Make a project's build and CI faster — measure where pipeline time goes, rank the hotspots, then audit only those — caching, test parallelism, test cost, install, compile, typecheck and lint, Docker and pipeline topology. Covers Node/TypeScript, Go, Rust, Python and JVM (Gradle, Maven); GitHub Actions first, other CIs via an adapter. Use when CI or the build is slow, tests take too long, or the user wants to cut build time or CI cost.
license: MIT
---

# optimize-build

**Measure first, then optimize only the hotspots.** A fix that does not shorten the critical path or cut
compute minutes is not a finding. Every claim carries seconds, from CI history or a local run.

```
 detect CI ──► measure ──► time budget ──► hotspots ──► Workflow ──────────────────► report
 + stack      (N runs)    (median/p90,     (Pareto      lane investigators ─► skeptic   (ranked by
 (adapter,                 critical path)   ≥80% of CP)  + cache/waste audit per lane    seconds saved)
  stack/*.md)                                            each reads lane ref + its stack refs
```

**Invoking this skill is the Workflow opt-in.** Do not ask again before step 4; state the agent count
there in one line (one investigator and one skeptic per hotspot, plus the two audits) and launch.

References come in two layers. **Lane references** (`references/*.md`) hold tool-agnostic guidance.
**Stack references** (`references/stack/<key>.md`) hold one technology's knobs, profiling and pitfalls,
and are read only when that technology is detected. Never read a stack file for a tool the repo lacks.

## 1. Detect the CI, the stack, and pick an adapter

Analyse the ref CI actually runs, not the user's working tree: `git fetch origin <default>` then
`git worktree add --detach <scratch>/repo origin/<default>` and run the pipeline's own install command
there. That directory is `repoDir` for the rest of the run; never measure in a tree with someone else's
edits. Reports are the one thing written to the user's tree (step 2). Remove the worktree when the run ends.

Run `bash <this skill's dir>/scripts/detect-stack.sh <repoDir>`. Each line is
`<key> <stack reference or -> <evidence>`. Keep the output: the workflow in step 4 takes the keys as
`args.stack`, and each investigator reads only the stack files for its lane. A `-` means detected but no
stack file yet — fall back to the lane reference and say so in the report.

To support a new technology: add a `by_path`/`by_dep` line to the script and a `references/stack/<key>.md`
in the shape of the existing ones (Measure, Checks, Cache paths, Version traps, Sources), then add the key
to `LANE_STACK` in [WORKFLOW.md](WORKFLOW.md).

Then pick the CI adapter:

| Found | Adapter |
| --- | --- |
| `.github/workflows/*.yml` | GitHub Actions — [references/ci-github-timings.md](references/ci-github-timings.md) |
| `.gitlab-ci.yml`, `.circleci/`, `.buildkite/`, `azure-pipelines.yml` | Not built yet. Use the adapter contract in `ci-github-timings.md`; if you cannot, use the local fallback and say so. |
| none, or no API access | Local fallback: time each script the pipeline would run (same file, "Fallback" section). |

Done when: the adapter and the detected stack keys are in your reply, and you have checked
`gh auth status` (or the CI's token) works.

## 2. Measure — build the time budget

Follow the adapter reference. Pull the last **20 successful runs on the default branch** per workflow
(fewer if history is short — say how many). For every job and step compute **median and p90**, queue
time separately, and the **critical path** through `needs:`.

Also count **runs per day** per workflow (last 14 days, all branches and events) — savings are
reported per run *and* per day.

Write the time budget to `docs/research/<YYYY-MM-DD>-build-time-budget.md` in the user's working tree
(or where that repo keeps such reports). Keep its absolute path: step 4 passes it as `budgetFile`.

```
| Workflow / job / step | median | p90 | on critical path | runner min/run | runs/day |
```

Done when: every job on the critical path has a median, and total wall-clock, runner minutes per run
and runs per day are stated per workflow.

## 3. Pick the hotspots

Sort critical-path steps by median. Take steps until they cover **≥80% of critical-path wall-clock**,
max 6. Add any off-path step in the top 3 by compute minutes. Tag each with one **lane**:

| Lane | Typical steps | Lane reference |
| --- | --- | --- |
| `test` | vitest, jest, playwright, pytest, go test, cargo test/nextest, gradle test, surefire | [test-parallelism.md](references/test-parallelism.md); JS/TS runners also [test-environment.md](references/test-environment.md) |
| `install` | npm ci, pnpm install, uv sync, pip install, go mod download, cargo fetch, dependency resolution, setup-* | [build-steps.md](references/build-steps.md), [ci-github-caching.md](references/ci-github-caching.md) |
| `typecheck-lint` | tsc, eslint, biome, mypy, ruff, go vet, golangci-lint, clippy, checkstyle | [build-steps.md](references/build-steps.md) |
| `build` | vite/next/webpack build, go build, cargo build, gradle assemble, mvn package | [build-steps.md](references/build-steps.md) |
| `docker` | docker build / buildx | [build-steps.md](references/build-steps.md), [ci-github-caching.md](references/ci-github-caching.md) |
| `topology` | queue time, serial jobs, duplicated setup | [build-steps.md](references/build-steps.md) |

Which stack files a lane loads is `LANE_STACK` in [WORKFLOW.md](WORKFLOW.md), intersected with the
detected keys.

Two audits always run, hotspot or not, because their waste hides across every lane:

- **cache audit** — missing, mis-keyed, PR-saved or evicted caches.
- **waste audit** — runs that should not happen at all: no `concurrency` cancel-in-progress, triggers
  without `paths`/job-level change gating, duplicate coverage across workflows, full matrix on every PR,
  write-back bots (formatters) running automatically instead of on a label.

For a `test` hotspot, also collect the slowest test files or packages (a report artifact, or a local
run with the runner's duration output) — the investigator needs them.

Done when: each hotspot has a lane, its median, its share of the critical path, and its evidence
(run URL or local command).

## 4. Run the investigation Workflow

Load [WORKFLOW.md](WORKFLOW.md) and run its script with the hotspots as `args`, after the one-line
agent count. One investigator per
hotspot plus the cache and waste audits, then one skeptic per lane that tries to refute each finding — by reading
config, and by measuring locally when the fix is cheap to try (e.g. gating a Tailwind plugin out of
tests, `isolate: false`, `go test -vet=off`, `CARGO_PROFILE_DEV_DEBUG=0`, `COVERAGE_CORE=sysmon`,
`org.gradle.parallel=true`).

**No Workflow tool** (headless runs, other agents): run the same investigator prompt, then the skeptic
prompt, per item from the script yourself, in sequence. Measure in a scratch copy, never the user's tree.

Done when: the workflow (or the sequential fallback) returned, and every surviving finding has evidence, an estimated saving in
seconds on the critical path, and a risk.

## Guardrails

A finding that breaks one is dropped (skeptics enforce these too):

1. **Never hide required validation** — release, migration, schema or shared-library checks keep running.
2. **Never trade latency for cost silently** — merging jobs or cutting parallelism needs the user to
   prefer cost, and the new critical path stays ≤ 1.25× the old.
3. **Matrix legs need a reason to go** — drop only legs with no documented version/platform commitment.
4. **Repo YAML and org settings are separate findings** — runner size, billing and cache quotas are not
   repo edits.

## 5. Report

Append to the time-budget file, ranked by **PR wall-clock saved**, then runner minutes/day, then effort:

```
| # | Finding | Lane | Wall-clock saved (s) | Runner min/day saved | Effort | Risk | Measured? | Evidence |
```

Keep three numbers apart — they answer different questions: **PR wall-clock** (feedback speed),
**runner minutes** (cost), **work avoided** (skipped runs/jobs/legs). Mark every saving as *measured*
or *expected*; never present an expected number as measured.

In chat: the top 3 findings, one line each, plus the file link. Do not apply fixes unless asked. When
asked, apply one finding per branch and re-measure after caches warm (≥ 3 runs). For trigger and
concurrency changes, prove them live on a non-protected branch: two quick pushes (cancel works), an
ignored-path-only push (heavy jobs skip). The first push of a new branch is not a valid path-filter test.

## Adding another CI

Write `references/ci-<name>.md` implementing the adapter contract from `ci-github-timings.md`, then add
a row to the table in step 1. Nothing else changes: steps 2–5 consume the contract, not the CI.

---
Guardrails, the waste audit and the three-number report adapted from
[github/awesome-copilot `github-actions-efficiency`](https://github.com/github/awesome-copilot/tree/main/skills/github-actions-efficiency) (MIT).
Docker lane checks adapted from [docker/skills `docker-build-strategies`](https://github.com/docker/skills/tree/main/skills/docker-build-strategies) (Apache-2.0).
Notices: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
