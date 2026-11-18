# GitHub Actions timings: measure where CI time goes (plus the adapter contract for other CIs)

> **Use when:** the MEASURE phase of `optimize-build`. You need p50/p90 job and step times, queue vs exec, and the critical path of a GitHub Actions workflow before you change anything.
> **Also use when:** writing an adapter for GitLab, CircleCI, Buildkite or Azure Pipelines (§10). Every downstream script reads one NDJSON shape.

Fact-checked 2026-11-09 (re-verified 2026-11-18: links, quoted passages, scripts and the highest-impact claims) with gh 2.103.3, jq 1.8.2, REST API version `2026-03-10`, and live runs of `vitest-dev/vitest`, `astral-sh/ruff`, `cli/cli` and `electron/electron`. Every script below was run on 2026-11-09. "Observed" means seen in live API data but not documented by GitHub, so re-check it if results look off. Tool versions current that day: Vitest 5.1.0, Jest 30.5.2, Playwright 1.65.0, hyperfine 2.0.0, actions/upload-artifact v7.0.2.

## 0. Procedure

1. Preflight: auth, rate budget, retention (§1).
2. Choose the workflow(s) that gate merges. Sample 20–50 successful runs on the default branch (§2).
3. Collect jobs and steps into NDJSON (§3), then aggregate p50/p90 per job and step, with queue and exec kept apart (§4).
4. Find the critical path and each job's slack (§5).
5. Rank. If the goal is wall-clock, rank by seconds on the critical path. If the goal is cost, rank by exec p50 × matrix legs. When queue time dominates, the limit is runner capacity, not the build.
6. Go deeper on the top 1–3 only, using logs and test reports (§6). If there is no CI history, time the commands locally (§8).
7. Save the NDJSON and the summary as the baseline. Re-run the same commands after each change.

## 1. Preflight, access, limits

```bash
gh auth status && gh api rate_limit --jq .resources.core
gh api repos/OWNER/REPO --jq .default_branch
gh api repos/OWNER/REPO/actions/workflows --jq '.workflows[] | [.id,.name,.path,.state] | @tsv'
```

| Credential | Works for | Primary limit |
|---|---|---|
| none | run, job and artifact metadata on public repos | 60/h. Job logs return **403 `Must have admin rights to Repository.`** (observed 2026-11-09, even though the docs say "anyone with read access" can download) |
| `gh auth login` / classic PAT | everything. Private repos need `repo` | 5,000/h |
| fine-grained PAT | `Actions: read` covers runs, jobs, logs, artifacts and timing. `Contents: read` covers workflow YAML ([permissions table](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)) | 5,000/h |
| `GITHUB_TOKEN` in a workflow | add `permissions: actions: read` if permissions are restricted | 1,000/h per repo (15,000 on GHEC) |

Sources: [rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api), [workflow jobs API](https://docs.github.com/en/rest/actions/workflow-jobs).

- **Secondary limits.** At most 100 concurrent requests and 900 points/min on REST. On 403 or 429: if there is a `retry-after` header, wait that long. If `x-ratelimit-remaining` is 0, wait until `x-ratelimit-reset`. Otherwise wait at least 1 min and back off exponentially ([source](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)). Fetch sequentially. A 5xx in the middle of `gh api --paginate` can end the listing early without an error (observed 2026-11-18 on gh 2.105.0: a 502 left 200 of 1,161 runs). Compare what you got with `total_count` from the first page and fetch again on a mismatch.
- **Budget.** Timings cost 1 + N × ceil(jobs/100) calls, so 50 runs with 25 jobs each is about 51 calls. Logs add 1 call per job, so fetch them only for the top jobs. Add `gh api --cache 1h` while you iterate.
- **Retention.** The default is 90 days. Public repos can set 1–90 days and private repos 1–400 ([docs](https://docs.github.com/en/organizations/managing-organization-settings/configuring-the-retention-period-for-github-actions-artifacts-and-logs-in-your-organization)). Since 2026-10-01 the same setting is meant to delete **runs, checks and statuses** too. Before that they were kept for 400+ days, and the change is not retroactive ([changelog 2026-08-27](https://github.blog/changelog/2026-08-27-actions-retention-will-cover-checks-workflow-runs-and-statuses)). Observed 2026-11-09: vitest and cli/cli still listed runs from 2026-07-30, more than 90 days old, along with their jobs. Logs for those runs returned **HTTP 410**. Treat logs as gone after the retention period and run metadata as possibly gone. Report artifacts often set a shorter `retention-days`, so download them on your first pass.
- **Forks.** Runs live in the repo that executed them, and PRs from forks run in the base repo. Check `gh run list -R FORK -L 5`. If the fork's history is empty or thin, measure upstream. Runs from first-time contributors sit in `action_required` until someone approves them ([runs API](https://docs.github.com/en/rest/actions/workflow-runs)). Keep them out of queue stats.
- **GHES:** the same endpoints work through `gh api --hostname HOST`. Older servers may be missing newer fields.

## 2. Pick the sample

```bash
gh run list -R O/R -w ci.yml -b main -s success -e push -L 50 --created '>=2026-10-01' \
  --json databaseId,attempt,createdAt,startedAt,updatedAt,headSha,event
```

- The REST equivalent is `GET /repos/{o}/{r}/actions/workflows/{file-or-id}/runs?branch=&status=success&event=push&per_page=100`. `per_page` has a maximum of 100. With any of `actor, branch, check_suite_id, created, event, head_sha, status` the endpoint returns **at most 1,000 results**. For longer windows, slice by `created=2026-10-01..2026-10-15` ([runs API](https://docs.github.com/en/rest/actions/workflow-runs)).
- **Use attempt 1 only, via `/attempts/1/jobs`.** Observed on vitest, ruff and vite after "re-run failed jobs": the attempt-N job list re-lists jobs that already passed. They get a **new job id, `run_attempt: N` and a new `created_at`** but keep the **original `started_at`/`completed_at`**, so `started_at < created_at` and queue time comes out negative. `?filter=all` returns every attempt. The default `latest` returns only the newest attempt ([jobs API](https://docs.github.com/en/rest/actions/workflow-jobs)). Full re-runs were not observed. Count runs with `run_attempt > 1` separately as a flakiness signal.
- **Keep events apart.** Sample `pull_request` and default-branch `push` separately. `pull_request` is what developers wait on and gives the PR wall-clock; `push` gives the delivery time. Path filters, `if:`, job sets and queueing can all differ between them. On vitest, push runs on main mostly queued 2–3 s per job, but job queues in one PR run (42643021918) ranged from 2 s to almost 6 min (median about 3 min). Merge queues run as `merge_group`. `schedule` and `workflow_dispatch` usually run different job sets.
- **Sample size.** Get at least 10 data points per job: 20–50 runs, or 14–30 days. Report p50 and p90, never the mean of a few runs. Jobs gated by `if:` or path filters will have a lower n, so always print n.
- **Regression hunt:** compare the p50 of the last 10 runs with the p50 of the 10 runs before them.

## 3. Jobs and steps → NDJSON

| Field | Meaning |
|---|---|
| `run.created_at` | event received. It does not change on re-runs |
| `run.run_started_at` | start of the *latest* attempt |
| `run.updated_at` | last modification. There is no `completed_at` on runs, so use `max(job.completed_at)` |
| `job.created_at` | **the moment the job became eligible**. Observed on vitest (22 jobs) and ruff (37 jobs): equal to the `completed_at` of its last `needs:` dependency, to the second. Undocumented, since the schema lists only the type ([jobs API](https://docs.github.com/en/rest/actions/workflow-jobs)) |
| `job.started_at` / `completed_at` | runner picked the job up / job finished. **Skipped jobs:** `started_at == created_at`, and `completed_at` can be 1 s *earlier* (ruff), so filter on `conclusion` |
| `job.labels`, `runner_name`, `runner_group_name` | runner type: hosted, self-hosted or third-party (e.g. ruff's `namespace-profile-*`), and size |
| `steps[].number/name/started_at/completed_at` | 1-second resolution. Numbers have gaps before the `Post …` steps (observed: post slots that never ran are omitted). Skipped steps are listed, with `conclusion: "skipped"`. Includes `Set up job`, `Post …` and `Complete job` |

- **`queue_s = started_at − created_at`** measures runner availability. Plan caps for standard hosted runners are Free 20, Pro 40, Team 60 and Enterprise 500 concurrent jobs. macOS is 5 (50 on Enterprise) and shared with larger runners ([limits](https://docs.github.com/en/actions/reference/limits), 2026 values). Other causes are `strategy.max-parallel`, the size of a self-hosted or third-party pool, and `environment:` protection rules. Read the YAML before you blame the plan.
- **`exec_s = completed_at − started_at`.**
- **Pre-start waits** (workflow-level concurrency group, fork approval) are **not verified**. On 25 vitest PR runs, `min(job.created_at) − run.created_at` was 0–1 s on every run, and no run that actually waited was found. Treat a large value there as a hint only. `GET /repos/{o}/{r}/actions/concurrency_groups/{name}?ahead_of_run=ID` shows what is queued ahead of a run, but only the live state, with no history ([docs](https://docs.github.com/en/rest/actions/concurrency-groups)).
- `gh run view RUN --json jobs` gives job and step `startedAt/completedAt` but **no job `createdAt`**, so it cannot give you queue time. Use the REST endpoint.

```bash
#!/usr/bin/env bash
# collect.sh OWNER/REPO WORKFLOW_FILE [N<=100] [EVENT] [BRANCH] > jobs.ndjson   (one line per successful attempt-1 job)
# EVENT defaults to push. BRANCH defaults to the default branch for push, and to every branch for other events.
set -euo pipefail
REPO=$1 WF=$2 N=${3:-30} EVENT=${4:-push} BRANCH=${5:-}
if [ -z "$BRANCH" ] && [ "$EVENT" = push ]; then BRANCH=$(gh api "repos/$REPO" --jq .default_branch); fi
gh api "repos/$REPO/actions/workflows/$WF/runs?status=success&event=$EVENT&exclude_pull_requests=true&per_page=$N${BRANCH:+&branch=$BRANCH}" \
  --jq '.workflow_runs[] | select(.run_attempt == 1) | [.id, .head_sha, .event] | @tsv' |
while IFS=$'\t' read -r RUN SHA EV; do
  gh api --paginate "repos/$REPO/actions/runs/$RUN/attempts/1/jobs?per_page=100" |
  jq -c --argjson run "$RUN" --arg sha "$SHA" --arg event "$EV" '
    def t: if . == null then null else fromdateiso8601 end;
    .jobs[] | select(.conclusion == "success") | {
      run: $run, sha: $sha, event: $event, job: .name, labels: (.labels | join(",")),
      created: .created_at, started: .started_at, completed: .completed_at,
      queue_s: ((.started_at|t) - (.created_at|t)),
      exec_s:  ((.completed_at|t) - (.started_at|t)),
      steps: [.steps[] | select(.conclusion == "success")
              | {name, s: ((.completed_at|t) - (.started_at|t))}] }'
done
```

`gh api --jq` has no `--arg`, so pipe into standalone `jq` when you need variables. Always pass `--paginate`, because a matrix can expand to 256 jobs per run ([limits](https://docs.github.com/en/actions/reference/limits)). The `run_attempt == 1` filter drops runs that were re-run, which biases the sample toward non-flaky runs. Report how many runs it dropped. Run it once per event you sample (`push`, `pull_request`, `merge_group`, or what else triggers the workflow: `workflow_run`, `release`, `repository_dispatch`) and keep one file per event; a workflow that never runs on `push` returns nothing with the default.

## 4. Aggregate (p50/p90 per job and step)

```jq
# agg.jq — jq -s -r -f agg.jq jobs.ndjson   (floor-rank percentiles, index floor((n-1)*p), at most one rank below nearest-rank; trust n >= 5)
def pct(p): sort | .[((length - 1) * p | floor)];
def stats(f): map(f) | {n: length, p50: pct(0.5), p90: pct(0.9)};
def norm: gsub("[0-9a-f]{40}"; "<sha>") | gsub("v?[0-9]+\\.[0-9]+\\.[0-9]+[-+.0-9A-Za-z]*"; "<ver>");   # names that change every run
map(.job |= norm) |
( group_by(.job) | map({k: .[0].job, x: stats(.exec_s), q: stats(.queue_s)})
  | sort_by(-.x.p50)[:15][] | "JOB\t\(.x.p50)s\tp90 \(.x.p90)s\tqueue p50 \(.q.p50)s\tn=\(.x.n)\t\(.k)" ),
( [ .[] | .job as $j | .steps[] | {k: "\($j) :: \(.name | gsub("@[0-9a-f]{40}"; ""))", s} ]
  | group_by(.k) | map({k: .[0].k, x: stats(.s)})
  | sort_by(-.x.p50)[:20][] | "STEP\t\(.x.p50)s\tp90 \(.x.p90)s\tn=\(.x.n)\t\(.k)" )
```

Real output from vitest CI, 6 runs: `JOB 713s p90 762s queue p50 3s n=6 Browsers: rest 2/2, node-24, windows-latest` and `STEP 626s … :: Test Browser (playwright)`. Test time dominates and queue time is negligible, so the next lane is test sharding and balance, not caching. Keep the `gsub`: steps that run a SHA-pinned action are named `Run owner/repo/.github/actions/x@<40-hex>`, and without stripping the SHA they never group across commits. `norm` does the same for job names: a release leg such as `build (app, 0.7.119)` would otherwise be an n=1 row per run. Drop the `<ver>` rule when a matrix compares three-part versions on purpose.

| Signal | Meaning | Next lane |
|---|---|---|
| p90 − p50 large relative to p50 | variable job: cache misses, network, noisy runner | compare the cache-restore steps across runs (`ci-github-caching.md`) |
| queue p50 > ~10% of exec | capacity: matrix width vs plan caps, macOS caps, pool size | topology. Caching will not help |
| one step ≈ job exec | that tool is the cost | the matching tool lane (§6 for tests) |

Steps shorter than 1 s show as 0, and the step sum is less than job exec because setup and the gaps between steps are not counted.

## 5. Critical path: wall-clock vs compute

Per run, **wall = max(completed) − min(created)** and **compute = Σ exec**. compute/wall is the effective parallelism. Only shortening a job **on the critical path** reduces wall-clock time. Any other change only saves compute.

**5a. Realized path from timestamps (no YAML needed).** This relies on the observed `job.created_at` semantics (§3). It walks backwards from the job that finished last.

```jq
# critpath.jq — jq -s -r --argjson run RUN_ID -f critpath.jq jobs.ndjson
def t: fromdateiso8601;
[ .[] | select(.run == $run) | . + {c: (.created|t), e: (.completed|t)} ] as $J
| ($J | min_by(.c).c) as $t0
| def walk($j): [$j] + ( [ $J[] | select(.e <= $j.c + 1 and .e >= $j.c - 2 and .job != $j.job) ]
                         | max_by(.e) | if . == null then [] else walk(.) end );
  "wall_clock_s=\(($J|max_by(.e).e) - $t0)  compute_s=\([$J[].exec_s]|add)  jobs=\($J|length)",
  ( walk($J | max_by(.e)) | reverse[] | "  +\(.c - $t0)s queue=\(.queue_s)s exec=\(.exec_s)s  \(.job)" )
```

Vitest run 42648475956: `wall_clock_s=799 compute_s=6243 jobs=22`, about 7.8× parallelism, with path `Diff (6s) → Browsers: rest 2/2, windows-latest (787s)`. Ruff run 42644367761: `wall 785 compute 8072 jobs 37`, with path `Determine changes (25s) → benchmarks instrumented ty (build) (252s) → … (simulation: micro-2) (501s)`. A serial build → bench chain is the target there. If two dependencies finish in the same second the walk may pick the wrong one, and on one real repo it missed an edge in 1 of 20 runs. Run it over every sampled run, take the most frequent path, and treat 5b as the authority when the two disagree. Cross-check: on run 42648475956, `GET …/runs/{id}/timing` returned `run_duration_ms: 800000`, matching the computed wall-clock.

**5b. Planned DAG from YAML (slack and what-if).** The API returns display names only, so map them back to job ids first.

```bash
gh api -H 'Accept: application/vnd.github.raw+json' "repos/O/R/contents/$WF_PATH?ref=$SHA" > ci.yml  # WF_PATH = run.path
npx -y js-yaml ci.yml > wf.json          # or: yq -o=json ci.yml > wf.json  (mikefarah yq v4)
```

| YAML | Display name in the API |
|---|---|
| no `name:`, no matrix | the job id |
| no `name:` + matrix | `id (v1, v2)`, e.g. `build (ubuntu-latest)` (cli/cli, observed) |
| `name:` with `${{ }}` | rendered. Turn each expression into `.*`; if several patterns match, keep the one with the most literal characters (vitest: `Test: ${{…}}` vs `Test: vite@7, ${{…}}`) |
| reusable workflow (`uses:`) | `caller / callee-job`, with one more ` / ` per nesting level, e.g. `linux-x64 / build / build` (electron, observed; not in GitHub docs) |
| `needs:` | a string or an array of job ids. A job that needs a matrix job waits for **all** of its legs |

```jq
# dag.jq — jq -s -r --slurpfile wf wf.json -f dag.jq jobs.ndjson
def esc: gsub("(?<c>[.+*?()\\[\\]{}|^$\\\\])"; "\\\(.c)");
def pct(p): sort | .[((length - 1) * p | floor)];
def t: fromdateiso8601;
($wf[0].jobs | to_entries | map({ id: .key,
   needs: (.value.needs // [] | if type == "string" then [.] else . end),
   pat: ( if .value.name then "^" + ([.value.name | splits("\\$\\{\\{[^}]*\\}\\}")] | map(esc) | join(".*")) + "$"
          else "^" + (.key | esc) + "( \\(.*\\))?( / .*)?$" end ),
   lit: ((.value.name // .key) | gsub("\\$\\{\\{[^}]*\\}\\}"; "") | length) })) as $P
| map(. as $j | . + {id: ([$P[] | . as $p | select($j.job | test($p.pat))] | max_by(.lit) | .id)})
| (map(select(.id == null) | .job) | unique) as $unmapped
| group_by(.id) | map(select(.[0].id != null) | {key: .[0].id, value: (     # node = first leg eligible → last leg done
    group_by(.run) | map((map(.completed|t) | max) - (map(.created|t) | min)) | pct(0.5))})
| from_entries as $D
| (reduce range($P|length) as $_ ({}; reduce $P[] as $p (.; .[$p.id] =
    ($D[$p.id] // 0) + ([$p.needs[] as $n | .[$n] // 0] | max // 0)))) as $F   # earliest finish
| ($F | to_entries | max_by(.value)) as $end
| def back($id): [$id] + ([$P[] | select(.id == $id) | .needs[]] | max_by($F[.]) // null
                          | if . == null then [] else back(.) end);
  "critical path p50 ≈ \($end.value)s: " + (back($end.key) | reverse | map("\(.) (\($D[.] // 0)s)") | join(" -> ")),
  ( (reduce range($P|length) as $_ ({}; . as $LF | reduce $P[] as $p (.; .[$p.id] =   # latest finish
      ([$P[] | select(.needs | index($p.id)) | ($LF[.id] // $end.value) - ($D[.id] // 0)] | min // $end.value))))
    | to_entries[] | "slack \(.value - $F[.key])s\t\(.key)" ),
  (if ($unmapped | length) > 0 then "UNMAPPED: \($unmapped)" else empty end)
```

Vitest, 6 runs: `critical path p50 ≈ 738s: changed (10s) -> test-browser-windows (728s)`. Slack was 0 s for both of those, 170 s for `test`, 350 s for `test-browser-linux` and 634 s for `lint`, so speeding up `lint` saves no wall-clock time.

- **Matrix:** a node takes as long as its slowest leg and costs Σ legs. Splitting or rebalancing the slowest leg moves wall-clock time. Trimming a fast leg only saves cost.
- If `UNMAPPED` lists anything, fix the mapping before you trust the path. Common causes are `name:` built from `${{ inputs.* }}` and reusable workflows called with a matrix.
- If measured wall-clock exceeds the planned path p50, the difference is queueing and scheduling, so look at `queue_s`.

## 6. Finer than steps: logs and test reports

**Logs.** `GET /repos/{o}/{r}/actions/jobs/{job_id}/logs` returns a 302 to a plain-text URL that expires after 1 minute. `GET …/jobs/{job_id}/steps/{step_number}/logs` returns one step only ([docs](https://docs.github.com/en/rest/actions/workflow-jobs), tested).

```bash
gh api --allow-escape-sequences repos/O/R/actions/jobs/$JOB/logs > job.log   # gh 2.103 exits 1 on ANSI output without the flag
```

- Line format: `2026-11-09T15:49:16.0877422Z <text>`, with 7 fractional digits and a UTF-8 BOM on line 1. `##[group]Run <cmd>` opens each step's command, including the sub-steps of composite actions. `Set up job` also emits groups such as `Runner Image`.
- `gh run view RUN --log --job ID` prints `job<TAB>step<TAB>ts line`. Its help warns that some lines may show as `UNKNOWN STEP`, and that the per-job fallback fails if more than 25 job logs are missing. Prefer the REST endpoint.

```python
# loggaps.py — python3 -I loggaps.py job.log [TOP]: slowest ##[group] sections + largest silent gaps
import sys, re
from datetime import datetime
ts_re = re.compile(r'^\ufeff?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.(\d+)Z (.*)$')
rows = [(datetime.fromisoformat(m[1] + '+00:00').timestamp() + float('0.' + m[2]), m[3])
        for m in (ts_re.match(l.rstrip('\n')) for l in open(sys.argv[1], encoding='utf-8', errors='replace')) if m]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 10
starts = [(t, x[9:][:100]) for t, x in rows if x.startswith('##[group]')] + [(rows[-1][0], None)]
secs = sorted(((b[0] - a[0], a[1]) for a, b in zip(starts, starts[1:])), reverse=True)
gaps = sorted(((b[0] - a[0], a[1][:100]) for a, b in zip(rows, rows[1:])), reverse=True)
print('# slowest sections');  [print(f'{d:8.1f}s  {n}') for d, n in secs[:top]]
print('# largest gaps (line before gap)');  [print(f'{d:8.1f}s  {n}') for d, n in gaps[:top]]
```

What to look for in the log:

- **Composite actions** are a single API step. Their internal cost only shows up in the log.
- **`Set up job`** includes downloading the actions.
- **`Initialize containers`** is the image pull for `services:` and `container:`.
- **`Post …`** steps are where cache saves run.
- **Long silent gaps** point to network or lock waits, or to one slow test.

**Tool summaries already in the log.** Strip ANSI codes first: `perl -pe 's/\e\[[0-9;]*m//g' job.log | grep -E 'Duration +[0-9]'`.

Runner summaries: the Vitest `Duration` line by version (and its v5 hint) is in [stack/vitest.md](stack/vitest.md) Measure §1–2; Playwright `reportSlowTests` defaults and per-file JSON sums are in [stack/playwright.md](stack/playwright.md) Measure.

**Test-report artifacts.**

```bash
gh api "repos/O/R/actions/runs/$RUN/artifacts" --jq '.artifacts[] | [.name,.size_in_bytes,.expires_at] | @tsv'
gh run download $RUN -R O/R -p '*result*' -D reports/$RUN       # -n NAME for exact names
# Vitest --reporter=json and Jest --json: testResults[].startTime/endTime are epoch ms per file (tested Vitest 5.1)
jq -r '.testResults | sort_by(.startTime - .endTime)[:25][] | "\((.endTime-.startTime)/1000)s\t\(.name)"' report.json
# Playwright JSON per-file sums: see stack/playwright.md (Measure)
# JUnit (Vitest/Playwright/jest-junit): rank files by total <testsuite time>, print the per-occurrence average
python3 -I -c 'import sys,glob,collections as C,xml.etree.ElementTree as E
t,n=C.Counter(),C.Counter()
for f in [p for a in sys.argv[1:] for p in glob.glob(a,recursive=True)]:
  for s in E.parse(f).getroot().iter("testsuite"): k=s.get("file") or s.get("name"); t[k]+=float(s.get("time") or 0); n[k]+=1
[print(f"{v/n[k]:8.2f}s x{n[k]} {k}") for k,v in t.most_common(25)]' 'reports/**/*.xml'
```

Sources: [Vitest reporters](https://vitest.dev/guide/reporters) (the JSON is Jest-compatible; use blob + `--merge-reports` for shards), [Jest formatTestResults](https://github.com/jestjs/jest/blob/main/packages/jest-test-result/src/formatTestResults.ts), [Playwright JSON types](https://github.com/microsoft/playwright/blob/v1.65.0/packages/playwright/types/testReporter.d.ts). Merge sharded reports before you rank files. Some reporters nest `<testsuite>` elements, and `iter()` counts nested ones twice.

An HTML-only report (Playwright's `html` reporter, a coverage site) has no stable format to parse, and the job log then has no per-test lines either. Do not write a parser. Get durations from a local run with a machine-readable reporter (`npx playwright test --reporter=json`, `--reporter=junit`), or from CI after the addition below.

If no machine-readable reports are uploaded, propose this one-time addition. It unblocks the test deep-dive:

```yaml
- run: npx vitest run --reporter=default --reporter=junit --outputFile.junit=reports/junit.xml
- uses: actions/upload-artifact@v7
  if: ${{ !cancelled() }}
  with: { name: "test-reports-${{ github.job }}-${{ strategy.job-index }}", path: reports/, retention-days: 14 }
```

- Reporter output flags (Vitest `--outputFile.<reporter>=` with two file reporters, Playwright JUnit via `PLAYWRIGHT_JUNIT_OUTPUT_NAME`): see [stack/vitest.md](stack/vitest.md) Measure §3 and [stack/playwright.md](stack/playwright.md) Measure.
- Artifact names must be unique within a run on v4+, because artifacts are immutable ([README](https://github.com/actions/upload-artifact#readme)). v7 adds `archive: false`, which uploads a single file unzipped and ignores `name` ([v7.0.0](https://github.com/actions/upload-artifact/releases/tag/v7.0.0)).

## 7. Timing endpoints and Insights

- `GET …/actions/runs/{id}/timing` and `…/workflows/{id}/timing` are marked "in the process of closing down" ([runs API](https://docs.github.com/en/rest/actions/workflow-runs), [2025-02-02 changelog](https://github.blog/changelog/2025-02-02-actions-get-workflow-usage-and-get-workflow-run-usage-endpoints-closing-down/)). Tested 2026-11-09 on public vitest: the run endpoint still returned 200 with `run_duration_ms` and `billable` per OS, but every `duration_ms` was 0. The workflow endpoint returned `{"billable":{}}`. `billable` covers only private repos on hosted runners, includes re-runs, and excludes the macOS/Windows multiplier. **Do not depend on these endpoints.** At most, use `run_duration_ms` to cross-check wall-clock time.
- **Insights → Actions Performance Metrics** (repo or org) shows average run time, average queue time and failure rate per workflow, job, OS and runner type. Custom ranges can be up to 100 days, reaching back at most 1 year. Usage metrics export to CSV ([concepts](https://docs.github.com/en/actions/concepts/metrics), [how-to](https://docs.github.com/en/actions/how-tos/administer/view-metrics)). It shows averages only, with no p90, and it is UI-only, so use it as a sanity check.

## 8. Fallback: no CI access or no history

1. Pull out the slow job's commands: `npx -y js-yaml .github/workflows/ci.yml | jq -r '.jobs.JOBID.steps[] | .run // empty'`.
2. Time them with **hyperfine 2.x**:
   ```bash
   hyperfine -S --warmup 1 --runs 5 --export-json warm.json 'npm run build'
   hyperfine -S --runs 3 --prepare 'rm -rf node_modules/.cache dist' --export-json cold.json 'npm run build'
   jq '.results[] | {command, mean: .summary.time_wall_clock.mean}' warm.json
   ```
   hyperfine 2.0.0 (2026-10-07) runs commands **without a shell by default**. `-S` is now an alias for `--shell=default` and restores `sh`, which you need for `&&`, pipes and `$VAR`. `--prepare/--setup/--conclude/--cleanup` always run in a shell. The JSON moved to schema v2: `results[].mean` became `results[].summary.time_wall_clock.mean` ([v2.0.0](https://github.com/sharkdp/hyperfine/releases/tag/v2.0.0)). **On 1.x**, drop `-S` (in 1.x it takes a shell argument, and a shell is already the default) and read `.results[].mean`. Check the version with `hyperfine --version`. Without hyperfine, time three runs and take the middle one: `for i in 1 2 3; do /usr/bin/time -p sh -c 'npm run build' 2>&1 | awk '/^real/{print $2}'; done | sort -n | sed -n 2p`.
3. Approximate the runner. `ubuntu-latest` has 2 vCPU / 8 GB in private repos and 4 vCPU / 16 GB in public ones. `macos-latest` is 3 vCPU (M1) / 7 GB ([runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)). For example: `docker run --rm --cpus=2 --memory=8g -v "$PWD":/w -w /w node:24 …`.
4. Caveats: a warm page cache and local package caches make local runs faster than a fresh VM, laptop cores are faster, and CI adds checkout, setup and cache restore/save. Trust **rankings and ratios**, not absolute seconds. Take at least 3 runs and report cold and warm separately.

## 9. Pitfalls

- Treating `run.updated_at − run.created_at` as duration. It includes queue time and re-runs, and `updated_at` can change later.
- Means over 3 runs. Mixing events. Including attempts > 1: copied jobs double-count and show negative queue.
- Calling Σ job time the "pipeline time". That is compute, not wall-clock.
- Optimizing a job that has slack. Check §5b first.
- Not normalizing step names that contain SHAs or rendered `${{ }}` values before grouping.
- Blaming the build for queue time. Caching does not fix plan caps, macOS caps, a small self-hosted pool, or environment approvals.
- Downloading report artifacts late. They often have a short `retention-days`, and expired logs return 410.
- Reading runner timings as wall time when they are worker time (Playwright `fullyParallel` per-file sums, Vitest 5 `Duration` percentages): see [stack/playwright.md](stack/playwright.md) and [stack/vitest.md](stack/vitest.md) Measure.

## 10. Adapter contract (CI-agnostic seam)

`agg.jq`, `critpath.jq` and `dag.jq` read only the §3 NDJSON shape (`run, sha, event, job, labels, created, started, completed, queue_s, exec_s, steps[{name,s}]`). A new CI only has to emit that shape, with `created` meaning **eligible** (dependencies satisfied).

```ts
type Iso = string;
interface RunRef { id: string; attempt: number; sha: string; branch: string; event: string; createdAt: Iso; url: string }
interface StepT  { name: string; number: number; startedAt: Iso | null; endedAt: Iso | null; status: string }
interface JobT {
  id: string; name: string; key?: string; matrix?: Record<string, string>;
  eligibleAt: Iso; startedAt: Iso; endedAt: Iso;            // queue = startedAt - eligibleAt
  status: 'success' | 'failure' | 'skipped' | 'other'; runner?: string; needs?: string[];
  steps: StepT[]; stepSource: 'api' | 'log-sections' | 'none';
}
interface CiAdapter {
  listRuns(q: { pipeline: string; branch: string; status: 'success'; event?: string; limit: number; since?: Iso }): Promise<RunRef[]>;
  getJobs(run: RunRef): Promise<JobT[]>;
  getLog(run: RunRef, job: JobT, step?: number): Promise<string>;
  listArtifacts(run: RunRef): Promise<{ id: string; name: string; bytes: number; expiresAt?: Iso }[]>;
  downloadArtifact(run: RunRef, artifactId: string, dir: string): Promise<string>;
  readPipelineConfig(run: RunRef): Promise<{ jobs: { key: string; nameTemplate?: string; needs: string[]; matrix: boolean }[] }>;
}
```

Rules: normalize timestamps to UTC, keep only successful jobs for timing, use the first attempt, and treat `pipeline` as the unit that has a run history. If a CI has no eligible timestamp, estimate it as max(dependencies' `endedAt`) and say so.

**GitHub Actions** (reference implementation, §2–§6): `listRuns` = `GET …/actions/workflows/{wf}/runs`. `getJobs` = `GET …/runs/{id}/attempts/1/jobs`, with `eligibleAt = created_at` (observed) and steps from the API. `getLog` = `…/jobs/{id}/logs` or `…/steps/{n}/logs`. Artifacts = `GET …/runs/{id}/artifacts`. Config = `GET …/contents/{run.path}?ref={sha}`. Edges come from the YAML only.

**GitLab CI** (REST v4):

- `listRuns` = `GET /projects/:id/pipelines?ref=main&status=success&source=push`. **List items carry no timings**, so call `GET /projects/:id/pipelines/:pipeline_id` for `duration`/`queued_duration`. The 19.4 timing fields belong to the user-scoped `GET /pipelines`, not to the project list ([pipelines](https://docs.gitlab.com/api/pipelines/)).
- `getJobs` = `GET /projects/:id/pipelines/:pipeline_id/jobs`. It returns `created_at, started_at, finished_at, duration, queued_duration, stage`, and leaves out retried jobs unless you pass `include_retried=true`. Child pipelines: `GET …/pipelines/:id/trigger_jobs`, which replaces `bridges` as of 19.2 ([jobs](https://docs.gitlab.com/api/jobs/)).
- Edges: `GET /projects/:id/ci/lint?content_ref=SHA&include_jobs=true` returns jobs with `stage` and `needs`, plus `merged_yaml` ([lint](https://docs.gitlab.com/api/lint/)). A job without `needs:` waits for every job in earlier stages ([needs](https://docs.gitlab.com/ci/yaml/#needs)).
- Steps: the API has none. `GET /projects/:id/jobs/:job_id/trace` has ISO 8601 timestamps on every line by default (GA in 18.9; turning them off with `FF_TIMESTAMPS` needs Runner 18.7+). Sections are marked `\e[0Ksection_start:UNIX_TS:name\r\e[0K` … `section_end` ([job logs](https://docs.gitlab.com/ci/jobs/job_logs/)).
- Tests: `GET …/pipelines/:pipeline_id/test_report`, built from `artifacts:reports:junit`.

**CircleCI** ([v2](https://circleci.com/docs/api/v2/index.html), [v3 jobs](https://circleci.com/docs/api/v3/jobs.md)):

- `listRuns` = `GET /api/v2/project/{slug}/pipeline?branch=main`, then `GET /api/v2/pipeline/{id}/workflow`.
- `getJobs` = `GET /api/v2/workflow/{id}/job`. Each job has `started_at, stopped_at, dependencies[]`, and the dependencies are the edges.
- Steps: v3 `GET /api/v3/jobs/:id` gives `queued_at, started_at, ended_at` and `parallel_executions[].steps[].started_at/ended_at`.
- Logs: `GET /api/v3/jobs/:id/stdout?filter[step_num]=N[&filter[execution]=K]`.
- Artifacts and tests: `/api/v3/jobs/:id/artifacts` and `/tests`, which returns JSON Lines. The v3 endpoints named here carry no preview label (the same page marks `/test-atoms` and `/testsuite-metadata` EXPERIMENTAL), but v3 is new, so pin to the documented fields.
- Shortcut: `GET /api/v2/insights/{slug}/workflows/{name}/jobs` returns server-side `duration_metrics` (`min, mean, median, p95, max, standard_deviation`).
- Config: `GET /api/v2/pipeline/{id}/config`, which includes `compiled`.

**Buildkite** ([builds API](https://buildkite.com/docs/apis/rest-api/builds)):

- `listRuns` = `GET /v2/organizations/{org}/pipelines/{p}/builds?branch=main&state=passed&created_from=…`. Jobs come embedded in each build; add `exclude_jobs=true` for cheap polling.
- Job timestamps are `created_at, scheduled_at, runnable_at` ("ready to be accepted by an agent", which maps to `eligibleAt`), `started_at` and `finished_at`. Jobs also carry `step_key`, `matrix` and `parallel_group_index`.
- Logs: `raw_log_url`. Agent v4 always emits ANSI timestamp codes. `---`, `+++` and `~~~` open groups ([log output](https://buildkite.com/docs/builds/managing-log-output)).
- Edges: `depends_on`/`wait` in the *uploaded* pipeline. With dynamic pipelines the repo YAML may be incomplete, so infer edges from `runnable_at` the way §5a does.

**Azure Pipelines** (REST 7.1):

- `listRuns` = `GET {org}/{project}/_apis/build/builds?definitions=ID&branchName=refs/heads/main&resultFilter=succeeded&statusFilter=completed&$top=N` ([list](https://learn.microsoft.com/en-us/rest/api/azure/devops/build/builds/list?view=azure-devops-rest-7.1)). Builds carry `queueTime, startTime, finishTime`.
- `getJobs` = `GET …/_apis/build/builds/{id}/timeline` ([timeline](https://learn.microsoft.com/en-us/rest/api/azure/devops/build/timeline/get?view=azure-devops-rest-7.1)). Records nest through `parentId` and carry `type, startTime, finishTime, attempt, workerName, log.id`. Records with a `task` reference are the steps. Records have **no queued timestamp**, so estimate queue as the job's `startTime` minus the latest `finishTime` among its dependencies.
- Edges: in YAML, jobs without `dependsOn` run in parallel by default, limited by agents and parallel-job licenses ([jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/phases?view=azure-devops)). Stages run sequentially unless `dependsOn` says otherwise, and `dependsOn: []` makes a stage parallel ([stages](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/stages?view=azure-devops)).
