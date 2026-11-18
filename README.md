# build-optimizer

An agent skill that makes a project's build and CI faster. It measures where pipeline time goes first, then audits only the steps that matter.

[![skills.sh](https://skills.sh/b/devnoo/build-optimizer)](https://skills.sh/devnoo/build-optimizer)

```
 detect CI ──► measure ──► time budget ──► hotspots ──► investigate ──► refute ──► report
 + stack      (20 runs)   (median/p90,     (≥80% of     one agent per   a skeptic   (ranked by
                           critical path)   the path)    hotspot         per finding  seconds saved)
```

## Install

```bash
npx skills add devnoo/build-optimizer
```

Works with any agent the [skills CLI](https://github.com/vercel-labs/skills) supports (Claude Code, Codex, Cursor, …).

## Use

Ask your agent: *"CI is slow, optimize the build"*, or invoke `optimize-build` by name.

You get one report: a time budget per workflow, job and step, then findings ranked by wall-clock seconds saved, each marked *measured* or *expected*. Nothing is changed in your repo unless you ask.

## What it covers

| Stack | Reference | Examples of what it checks |
| --- | --- | --- |
| Node, TypeScript | `node-pm`, `typescript`, `lint`, `vite`, `nextjs`, `vitest`, `jest`, `playwright`, `turbo`, `nx` | frozen installs, store caches, test environment cost, typecheck caches |
| Go | `go` | frozen build cache, test-result cache misses, `-race` on every leg |
| Rust | `rust` | dependency cache shape, double builds, nextest archives for shards |
| Python | `python` | locked installs, uv cache pruning, fixture and coverage cost |
| JVM | `jvm`, `gradle`, `maven` | build and configuration cache, Spring context churn, fork settings |
| Docker | `docker` | layer order, cache backends, multi-arch |
| Any | lane references | cache keys and scope, test parallelism and sharding, pipeline topology, wasted runs |

Long-running tests are part of the test lane: the skill ranks them, then profiles the worst ones one at a time (pprof, pyinstrument, JFR, samply, Vitest CPU profiles) to say whether a test is computing or waiting.

Timings come from GitHub Actions. Other CIs plug in through the adapter contract in [`ci-github-timings.md`](skills/optimize-build/references/ci-github-timings.md) §10; without CI access the skill times the pipeline's commands locally.

## Requirements

- `git`, `jq`, and an authenticated `gh` for GitHub Actions timings.
- In Claude Code the investigation fans out with the Workflow tool: one investigator and one skeptic per item, where the items are up to 6 hotspots plus a cache audit and a waste audit. That is at most 16 agents, at roughly 0.2 M tokens each; the skill states the count before it starts. Other agents run the same prompts in sequence.

## How the references are sourced

Every stack reference states the date it was checked and the tool versions that day. Each claim is tagged:

- **cited** — a linked vendor or maintainer statement.
- **local** — run or read on a real install that day.
- **heuristic** — typical but unmeasured. The skill must measure it on your repo before claiming a gain.

Build tools move fast. Treat a reference older than a few months as a starting point and check the repo's own versions.

## Add a stack

1. Add a `by_path` or `by_dep` line to [`scripts/detect-stack.sh`](skills/optimize-build/scripts/detect-stack.sh).
2. Write `references/stack/<key>.md` in the shape of the existing ones: Measure, Checks, Cache paths, Version traps, Sources.
3. Add the key to `LANE_STACK` in [`WORKFLOW.md`](skills/optimize-build/WORKFLOW.md).
4. Add a fixture to `tests/detect-stack.test.sh` and run the tests: `for t in tests/*.test.sh; do bash "$t"; done`.

## License

MIT. Parts are adapted from [github/awesome-copilot](https://github.com/github/awesome-copilot) (MIT) and [docker/skills](https://github.com/docker/skills) (Apache-2.0); see [THIRD-PARTY-LICENSES.md](skills/optimize-build/THIRD-PARTY-LICENSES.md).
