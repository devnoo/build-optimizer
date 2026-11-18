---
name: optimize-build
description: Make a project's build and CI faster — measure where pipeline time goes, rank the hotspots, then audit only those — caching, test parallelism, test cost, install, compile, typecheck and lint, Docker and pipeline topology. Covers Node/TypeScript, Go, Rust, Python and JVM (Gradle, Maven); GitHub Actions first, other CIs via an adapter. Use when CI or the build is slow, tests take too long, or the user wants to cut build time or CI cost.
license: MIT
---

# optimize-build

**Measure first, then optimize only the hotspots.** A fix that does not shorten the critical path or cut
runner minutes is not a finding. Every claim carries seconds, from CI history or a local run.

```
 detect CI ──► measure ──► time budget ──► hotspots ──► Workflow ──────────────────► report ──► clean up
 + stack      (N runs)    (median/p90,     (Pareto      per item: investigator       (ranked by
 (adapter,                 critical path)   ≥80% of CP)  ─► skeptic; items are the    seconds saved)
  stack/*.md)                                            hotspots + cache + waste audit
```

**Invoking this skill is the Workflow opt-in.** Do not ask again before step 4. There, state the agent
count and the expected cost in one line, then launch.

References come in two layers. **Lane references** (`references/*.md`) hold tool-agnostic guidance.
**Stack references** (`references/stack/<key>.md`) hold one technology's knobs, profiling and pitfalls,
and are read only when that technology is detected. Never read a stack file for a tool the repo lacks.

Shell snippets in this skill are bash. Under another shell (zsh is the macOS default) run them with
`bash -c` or a `bash <<'EOF'` heredoc: zsh aborts on unmatched globs and, with `noclobber`, refuses `> file`.

## 1. Detect the CI, the stack, and pick an adapter

Pick one **scratch directory** outside the repo: a fresh `mktemp -d`, or the harness's per-session storage.
Everything this run creates goes under it: `<scratch>/repo`, `<scratch>/data` (run data, logs, reports)
and `<scratch>/copies` (step 4).

Analyse the ref CI actually runs, not the user's working tree:

```bash
git fetch origin <default>
git -c core.hooksPath=/dev/null worktree add --detach <scratch>/repo origin/<default>   # the user's git hooks stay out of it
```

Run the pipeline's own install command there. That directory is `repoDir` for the rest of the run; never
measure in a tree with someone else's edits. A checkout that is already clean and at `origin/<default>`
(a CI job, an agent's own worktree) can serve as `repoDir` as it is.

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

Follow the adapter reference. Save what you fetch under `<scratch>/data`; step 4 hands it to the agents.

**Which workflows.** Measure the ones a merge or a deploy waits on: workflows triggered by `pull_request`,
`merge_group` or a `push` to the default branch, and the workflows those start (`workflow_run`,
`workflow_call`). For every other workflow (schedules, bots, manual dispatch) only count runs and billed
minutes per day; they feed the waste audit.

**Which runs.** Sample `pull_request` runs and default-branch `push` runs separately, 20 successful runs
each (fewer if history is short — say how many). Their job sets often differ: affected-only tests on PRs,
deploys on push. PR runs give the **PR wall-clock** the report ranks by; push runs give the delivery time.
If the user named one of them, that event drives the hotspots. Otherwise PR runs do, plus any job that
runs only on push and sits on that event's critical path.

For every job and step compute **median and p90**, queue time separately, and the **critical path**
through `needs:`.

**Cost.** Per workflow, over the last 14 days and all branches and events:

- **Runs per day by conclusion.** Skipped and cancelled runs cost little or nothing. Count them, and
  multiply savings only by the runs that executed.
- **Billed minutes per run:** each job's duration rounded up to a whole minute, summed over its jobs. Keep
  the compute seconds too: a 9-second job that runs 80 times a day bills 80 minutes.

Write the time budget to `docs/research/<YYYY-MM-DD>-build-time-budget.md` in the user's working tree, or
where that repo keeps such reports. If `docs/` is published (a site generator config, or a workflow that
deploys it), write it under `<scratch>/data` instead and say so. Keep its absolute path: step 4 passes it
as `budgetFile`.

```
| Workflow | event | wall-clock median / p90 | billed min/run | runs/day (ok / failed / cancelled / skipped) | billed min/day |
| Job › step | median | p90 | on critical path | slack |
```

Done when: every job on the critical path has a median, and each measured workflow has its wall-clock per
event, its billed minutes per run and its runs per day by conclusion.

## 3. Pick the hotspots

Sort critical-path steps by median and take steps until they cover **≥80% of critical-path wall-clock**.
Then add the off-path steps that cost the most **billed minutes per day** across all measured workflows.
Count a step that repeats in several jobs (the install, a toolchain setup) once, with its time summed.
**At most 6 hotspots in total, at most 2 of them off-path.** Two steps of the same lane in one job are one
hotspot. Tag each with one **lane**:

| Lane | Typical steps | Lane reference |
| --- | --- | --- |
| `test` | vitest, jest, playwright, pytest, go test, cargo test/nextest, gradle test, surefire | [test-parallelism.md](references/test-parallelism.md); JS/TS runners also [test-environment.md](references/test-environment.md) |
| `install` | npm ci, pnpm install, uv sync, pip install, go mod download, cargo fetch, dependency resolution, toolchain installers (setup-*, mise, asdf) | [build-steps.md](references/build-steps.md), [ci-github-caching.md](references/ci-github-caching.md) |
| `typecheck-lint` | tsc, eslint, biome, mypy, ruff, go vet, golangci-lint, clippy, checkstyle | [build-steps.md](references/build-steps.md) |
| `build` | vite/next/webpack build, go build, cargo build, gradle assemble, mvn package | [build-steps.md](references/build-steps.md) |
| `docker` | docker build / buildx | [build-steps.md](references/build-steps.md), [ci-github-caching.md](references/ci-github-caching.md) |
| `topology` | queue time, serial jobs, duplicated setup, and any step that fits no other lane | [build-steps.md](references/build-steps.md) |

Which stack files a lane loads is `LANE_STACK` in [WORKFLOW.md](WORKFLOW.md), intersected with the
detected keys.

Two audits always run, hotspot or not, because their waste hides across every lane:

- **cache audit** — missing, mis-keyed, PR-saved or evicted caches.
- **waste audit** — runs that should not happen at all: no `concurrency` cancel-in-progress, triggers
  without `paths`/job-level change gating, duplicate coverage across workflows, full matrix on every PR,
  write-back bots (formatters) running automatically instead of on a label.

For a `test` hotspot, also put the slowest test files or packages in `<scratch>/data`: a JSON or JUnit
report artifact, or a local run with the runner's duration output. When CI keeps only an HTML report, run
the suite locally with a machine-readable reporter instead of parsing the HTML (`ci-github-timings.md` §6).
Investigators receive this data and do not collect it again.

Done when: each hotspot has a lane, its median, its share of the critical path (or its billed minutes per
day when off-path), and its evidence (run URL or local command).

## 4. Run the investigation Workflow

Load [WORKFLOW.md](WORKFLOW.md) and run its script. The **items** are the hotspots plus the cache audit and
the waste audit. Each item gets one investigator, then one skeptic, so the run starts **2 × items agents**:
6 hotspots make 16. Say that count in one line with the expected cost — roughly 0.2 M tokens and a few
minutes per agent — then launch. If the session caps agents lower, merge hotspots of the same lane into
one item until it fits, and say which ones you merged.

The skeptic tries to refute each finding: by reading config, and by measuring in a scratch copy when the
fix is cheap to try (e.g. gating a Tailwind plugin out of tests, `isolate: false`, `go test -vet=off`,
`CARGO_PROFILE_DEV_DEBUG=0`, `COVERAGE_CORE=sysmon`, `org.gradle.parallel=true`).

**No Workflow tool** (headless runs, other agents): run the same investigator prompt, then the skeptic
prompt, per item from the script yourself, in sequence. Measure in a scratch copy, never the user's tree.

Done when: the workflow (or the sequential fallback) returned, and every surviving finding has evidence, a
saving in critical-path seconds or in billed minutes per day, and a risk.

## Guardrails

A finding that breaks one is dropped (skeptics enforce these too):

1. **Never hide required validation** — release, migration, schema or shared-library checks keep running.
2. **Never trade latency for cost, or cost for latency, silently** — merging jobs or cutting parallelism
   needs the user to prefer cost, and the new critical path stays ≤ 1.25× the old. Sharding, extra
   parallel jobs and larger runners state the billed minutes per day they add and need the user's OK.
3. **Matrix legs need a reason to go** — drop only legs with no documented version/platform commitment.
4. **Repo YAML and org settings are separate findings** — runner size, billing and cache quotas are not
   repo edits.

## 5. Report

Findings with the same `target` (the file and setting the fix changes) are one finding. Keep it if any
skeptic confirmed it, with the measured number where there is one.

Append to the time-budget file, ranked by **PR wall-clock saved**, then billed minutes/day, then effort:

```
| # | Finding | Lane | Wall-clock saved (s) | Billed min/day saved | Effort | Risk | Measured? | Evidence |
```

**Savings do not add up.** Applying the top finding moves the critical path. Recompute the path with that
finding applied, and credit each later finding only up to the slack that is left. Mark a finding that
pays off only if an earlier one is skipped as an alternative to it. State the critical path before and
after the top finding.

Keep three numbers apart — they answer different questions: **PR wall-clock** (feedback speed),
**billed minutes** (cost), **work avoided** (skipped runs/jobs/legs). Mark every saving as *measured*
or *expected*; never present an expected number as measured.

In chat: the top 3 findings, one line each, plus the file link. Do not apply fixes unless asked. When
asked, apply one finding per branch and re-measure after caches warm (≥ 3 runs). For trigger and
concurrency changes, prove them live on a non-protected branch: two quick pushes (cancel works), an
ignored-path-only push (heavy jobs skip). The first push of a new branch is not a valid path-filter test.

## 6. Clean up

Remove what the run created: each scratch copy (`bash scripts/scratch-copy.sh --remove <dir>`), the
worktree (`git worktree remove --force <scratch>/repo`, then `git worktree prune`), any container or
service an agent started, and `<scratch>` itself. Keep the report.

Done when: `git worktree list` shows nothing under `<scratch>` and the directory is gone.

## Adding another CI

Write `references/ci-<name>.md` implementing the adapter contract from `ci-github-timings.md`, then add
a row to the table in step 1. Nothing else changes: steps 2–5 consume the contract, not the CI.

---
Guardrails, the waste audit and the three-number report adapted from
[github/awesome-copilot `github-actions-efficiency`](https://github.com/github/awesome-copilot/tree/main/skills/github-actions-efficiency) (MIT).
Docker lane checks adapted from [docker/skills `docker-build-strategies`](https://github.com/docker/skills/tree/main/skills/docker-build-strategies) (Apache-2.0).
Notices: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
