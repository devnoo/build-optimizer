# CI caching reference: GitHub Actions first, GitLab/CircleCI mapped (fact-checked 2026-11-09, re-verified 2026-11-18)

Use when: measurements show restore, install, or build steps among the slowest, or caches miss, go stale, or thrash.
Covers actions/cache semantics, detection commands, setup-* caches, tool caches, anti-patterns, and fixes.

**Rule zero:** a cache is worth keeping only if `restore + save < the work it saves`. Compare the step timings (§2.3) before and after every change. Any gain this file does not source is marked *typical, unmeasured*.

---

## 0. Version snapshot (check again with `gh api repos/<o>/<r>/releases/latest`)
| Action | Latest as of 2026-11-18 | Notes |
|---|---|---|
| actions/cache | **v6.1.0** (2026-06-26) | v6.0.0 (2026-06-23) is the ESM build. v5.0.0 (2025-12-11) moved to Node 24 and needs runner ≥ 2.327.1. v5.0.2 stopped retrying HTTP 429 on save. v6.1.0 and v5.1.0 report a save blocked by a read-only token as a `cache write denied` warning (the job did not fail before either; older versions logged a generic `Unable to reserve cache … another job may be creating this cache` line) ([releases](https://github.com/actions/cache/releases)) |
| actions/setup-node | v7.1.0 | v7.0.0 (2026-07-14) added the `cache-primary-key`/`cache-matched-key` outputs. v7.1.0 bundles `@actions/cache` 6.3.0 ([releases](https://github.com/actions/setup-node/releases)) |
| setup-python / setup-go / setup-java | v7.1.0 / v7.1.0 / v6.3.0 | see the release pages |
| gradle/actions | v6.4.1 | |
| pnpm/setup / pnpm/action-setup | v3.2.0 / v6.1.1 | both maintained |
| astral-sh/setup-uv | v10.3.3 | |

Docker action versions: see [stack/docker.md](stack/docker.md).

**Old actions/cache pins**
- Versions below **4.2.0 / 3.4.0** fail outright: the deprecated versions were retired on 2025-03-01 and the legacy cache service was switched off on 2025-04-15 ([announcement](https://github.com/actions/cache/discussions/1510), [changelog](https://github.blog/changelog/2025-03-20-notification-of-upcoming-breaking-changes-in-github-actions/)). The floating `@v3` and `@v4` tags resolve to working versions.
- `@v4` declares `node20` and v3.5.0 declares `node16`. They still run, because hosted runners have run JS actions on Node 24 by default since 2026-06-16. The Node 20 opt-out (`ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION`) ended on 2026-09-23 ([deprecation changelog](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/), [removal](https://github.blog/changelog/2026-09-23-node-20-is-no-longer-available-in-github-actions)).
- Upgrade to v6 anyway. Pins below v5.1.0 miss the read-only (`cache write denied`) handling described in §1.4. No tagged release, `@v6` included, honors `ACTIONS_CACHE_MODE` yet.

---

## 1. actions/cache semantics

### 1.1 Key matching
- **Lookup order**, all in the run's branch scope:
  1. exact `key` + *version*;
  2. prefix match on `key`;
  3. each `restore-keys` entry, in order.
  If nothing matches, the same steps repeat in the **default-branch** scope, and for PR runs also in the base-branch scope. When several caches match a prefix, the **most recently created** one wins ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
- ***Version*** = SHA-256 of the `path` list + compression method, + `windows-only` on Windows unless `enableCrossOsArchive: true` ([toolkit `getCacheVersion`](https://github.com/actions/toolkit/blob/main/packages/cache/src/internal/cacheUtils.ts)). Consequences:
  - A different `path` between save and restore gives a **silent miss** ([caching-strategies](https://github.com/actions/cache/blob/main/caching-strategies.md)).
  - **CPU arch is not in the version.** Linux x64 and arm64 restore each other's caches unless the key contains `runner.arch`.
- **`cache-hit` output** ([restoreImpl.ts](https://github.com/actions/cache/blob/main/src/restoreImpl.ts), [restore README](https://github.com/actions/cache/blob/main/restore/README.md)):

  | Result | `cache-hit` |
  |---|---|
  | Exact primary-key match | `'true'` |
  | `restore-keys` match | `'false'` |
  | Miss | not set (`''`, deliberately, [#1466](https://github.com/actions/cache/issues/1466)) |

  Always gate on `!= 'true'`, never on `== 'false'`.
- `actions/cache/restore` also outputs `cache-primary-key` and `cache-matched-key`.
- `hashFiles()` returns an **empty string when nothing matches** ([expressions](https://docs.github.com/en/actions/reference/workflows-and-actions/expressions)). The runner aborts it after **120 s** with `hashFiles('…') couldn't finish within 120 seconds.` ([runner source](https://github.com/actions/runner/blob/main/src/Runner.Worker/Expressions/HashFilesFunction.cs)).

### 1.2 Immutability and saving
- Entries are immutable. Changed contents need a new key. On an exact hit the post step logs `Cache hit occurred on the primary key K, not saving cache.` ([saveImpl.ts](https://github.com/actions/cache/blob/main/src/saveImpl.ts)).
- The combined action saves in a post step with `post-if: success()`, so **a failed job saves nothing** ([action.yml](https://github.com/actions/cache/blob/main/action.yml)).
- `save-always` is deprecated ("does not work as intended", [action.yml](https://github.com/actions/cache/blob/main/action.yml)). Use `actions/cache/save` with `if: always() && steps.<restore>.outputs.cache-hit != 'true'` instead ([save README](https://github.com/actions/cache/blob/main/save/README.md)).
- For caches that grow without their inputs changing, use key `…-${{ github.run_id }}` plus a `restore-keys` prefix. This writes one new entry per run, which costs quota ([tips](https://github.com/actions/cache/blob/main/tips-and-workarounds.md)).
- The toolkit **builds the tar archive before reserving the key** ([cache.ts](https://github.com/actions/toolkit/blob/main/packages/cache/src/cache.ts)). A save that is denied or loses a race has already paid the archive time.

### 1.3 Scope
- A run can restore from:
  - its own branch;
  - the default branch;
  - for PR runs, the base branch.

  It cannot restore from child or sibling branches, or from other tags ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
- PR runs save into `refs/pull/<n>/merge`. The docs say such a cache "can only be restored by re-runs of the pull request" and never by the base branch or other PRs.
  - Later pushes to the same PR share that ref, so they *probably* hit too. That is an inference: confirm with `gh cache list --ref refs/pull/<n>/merge` and the restore log.
  - Either way, PR caches use quota that `main` cannot benefit from.

### 1.4 Low-trust triggers and `cache-mode`
- **Read-only default** (since 2026-06-26):
  - Only `push`, `schedule`, `workflow_dispatch`, `repository_dispatch`, `delete`, `registry_package` and `page_build` may write to the default-branch scope.
  - Any other event that resolves to the default branch gets read-only access. Examples: `pull_request_target`, `issue_comment`, and `workflow_run`, including fork-PR cascades.
  - `pull_request` and `release` write to their own scope, so this restriction does not affect them.
  - A blocked save is a warning, and the job continues ([changelog](https://github.blog/changelog/2026-06-26-read-only-actions-cache-for-untrusted-triggers/), [docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
- **`cache-mode`** (GA 2026-09-10, github.com):
  - Set at workflow level or `jobs.<id>.cache-mode`. The job value wins.
  - Values: `read` (restore only), `write` (both), `write-only` (save only), `none`.
  - When omitted: `write` for trusted triggers, `read` for low-trust triggers.
  - It is enforced with scoped tokens. Declaring `write`/`write-only` on a low-trust trigger adds a warning annotation and reopens cache poisoning ([changelog](https://github.blog/changelog/2026-09-10-control-github-actions-cache-access-with-cache-mode), [syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#cache-mode)).
  - It also caps reusable workflows that the job calls.
  - Expression support is **undocumented**, so use literal values.
- **`ACTIONS_CACHE_MODE`:**
  - The runner exports the effective mode. `@actions/cache` **5.2.0 / 6.2.0+** skips the restore or save cleanly and logs `Cache save skipped: the effective cache-mode 'read' does not permit writes.` ([toolkit RELEASES](https://github.com/actions/toolkit/blob/main/packages/cache/RELEASES.md)).
  - **actions/cache v6.1.0 (and `@v6`) still bundles toolkit 6.1.0.** The 6.2.0 bump was merged to `main` on 2026-07-15 but is untagged. With `@v6`, a save under `read` therefore builds the archive, then logs `Failed to save: … cache write denied: …`.
  - setup-node v7.1.0 bundles 6.3.0.

### 1.5 Limits, eviction, rate limits
- **10 GB per repo free.** Entries not accessed for 7 days are removed. Over the limit, the new entry is saved and entries are evicted by last access, oldest first ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
- **Raising the limits** (since 2025-11-20):
  - Admins can raise the "cache size eviction limit (GB)" and the "cache retention limit (days)". This needs a Pro, Team or Enterprise account ([changelog](https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/)).
  - User-owned repos can go up to 10 TB. Docs cost examples: 50 GB ≈ $2.80/mo, 200 GB ≈ $13.30/mo.
  - If a budget is exceeded, the cache becomes **read-only** ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
- **Eviction interval** changed from every 24 h to **every hour**, enforced from "November" 2025 (the changelog gives no exact day). Over-quota repos therefore thrash within the hour ([changelog](https://github.blog/changelog/2025-09-29-new-date-for-enforcement-of-cache-eviction-policy/)).
- **Rate limits:** 200 uploads/min and 1500 downloads/min per repo. Over them, calls fail until the `Retry-After` time ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)).
- **Stalled downloads:** a stuck download segment aborts after `SEGMENT_DOWNLOAD_TIMEOUT_MINS` (default 10), and the run continues as a miss ([tips](https://github.com/actions/cache/blob/main/tips-and-workarounds.md)).

---

## 2. Detection

### 2.1 YAML greps
```bash
W=.github/workflows
grep -rnE 'actions/cache(/restore|/save)?@|cache:|cache-dependency-path|package-manager-cache|enable-cache|cache-read-only|cache-from|cache-to|setup-gradle|cache-mode|restore-keys|save-always' $W
grep -rnE 'npm (ci|install)|pnpm i(nstall)?|yarn( install)?$|bun install|pip install|uv sync|poetry install|playwright install|gradlew?|mvn|docker (build|buildx)|next build|turbo run|nx (run|affected)|tsc|eslint|vitest|jest' $W
grep -rnE 'actions/cache(/\w+)?@(v[12]\b|v3\.[0-3]\.|v4\.[01]\.)' $W   # broken since 2025-03-01
```
Flag these:
- Install/build commands in a job with no cache.
- `key:` without `hashFiles(…)`.
- `key:` with `github.sha`/`run_id` but no `restore-keys`.
- `path: node_modules` together with `restore-keys`.
- The same directory cached twice, for example setup-node `cache: npm` plus `actions/cache` on `~/.npm`.
- Docker `type=gha` cache without a per-image `scope`: see [stack/docker.md](stack/docker.md) check 4.
- `save-always`.

### 2.2 Log signatures (`gh run view <id> --log`, or `gh api repos/{owner}/{repo}/actions/jobs/<job_id>/logs`)
| Line | Meaning |
|---|---|
| `Cache hit for: K` / `Cache hit for restore-key: K` | Exact or partial hit. Told apart only by toolkit ≥ 4.0.4, i.e. actions/cache ≥ 4.2.4; toolkit 4.0.0–4.0.3 (actions/cache 4.2.0–4.2.3 and 3.4.0) logs `Cache hit for: <primary key>` for every hit, restore-key matches included ([toolkit RELEASES](https://github.com/actions/toolkit/blob/main/packages/cache/RELEASES.md)) |
| `Cache restored from key: K` | Restore done (actions/cache and setup-node) |
| `Cache not found for input keys: …` / `<pm> cache is not found` | Miss (actions/cache / setup-node, [cache-restore.ts](https://github.com/actions/setup-node/blob/main/src/cache-restore.ts)) |
| `Cache Size: ~N MB (B)` | Archive size: input to the "too big" check |
| `Cache saved with key: K` / `Cache saved with the key: K` | Saved (actions/cache / setup-node) |
| `Failed to save: Unable to reserve cache with key K, another job may be creating this cache` | Concurrent save of the same key (info level) |
| `Failed to save: … cache write denied: …` | Read-only token: low-trust trigger, `cache-mode: read`, or budget exceeded |
| `Cache save skipped: the effective cache-mode …` / `Cache restore skipped: …` | Toolkit ≥ 6.2 honoring `ACTIONS_CACHE_MODE` |
| key ending in `-` | `hashFiles` matched nothing |

### 2.3 Step timing and hit rate
- With gh 2.103.3 the `--log` step column reads `UNKNOWN STEP` (observed on two repos). Use the jobs JSON instead. Resolution is 1 s, and `Post <step>` rows are the save cost:
  ```bash
  gh run view <id> --json jobs --jq '.jobs[]|.name as $j|.steps[]|select(.completedAt and .startedAt)|[$j,.name,((.completedAt|fromdate)-(.startedAt|fromdate))]|@tsv' | sort -t$'\t' -k3 -nr
  ```
- Hit rate over recent default-branch runs:
  ```bash
  for id in $(gh run list -b main -w ci.yml -L 20 --json databaseId -q '.[].databaseId'); do gh run view $id --log |
    grep -oE 'Cache hit for( restore-key)?: [^ ]+|Cache not found for input keys: [^,]+|[a-z]+ cache is not found'; done | sort | uniq -c
  ```

### 2.4 Quota ([REST](https://docs.github.com/en/rest/actions/cache), [gh cache list](https://cli.github.com/manual/gh_cache_list))
```bash
gh api 'repos/{owner}/{repo}/actions/cache/usage'            # active_caches_size_in_bytes, active_caches_count (~5 min lag)
gh api 'repos/{owner}/{repo}/actions/cache/storage-limit'    # max_cache_size_gb       (needs admin:repository scope)
gh api 'repos/{owner}/{repo}/actions/cache/retention-limit'  # max_cache_retention_days (same)
gh cache list -L 1000 -S size_in_bytes --json key,ref,sizeInBytes,createdAt,lastAccessedAt \
  --jq 'group_by(.ref)|map({ref:.[0].ref,n:length,mb:((map(.sizeInBytes)|add)/1048576|floor)})|sort_by(-.mb)'
```
For the whole org: `GET /orgs/{org}/actions/cache/usage-by-repository`.

How Docker `type=gha` entries appear in this list: see [stack/docker.md](stack/docker.md) Cache paths.

### 2.5 Symptom → cause
| Symptom | Likely causes |
|---|---|
| **Missing**: slow install, no cache lines | No cache step. setup-node v6+ auto-caches **npm only**, and only when `packageManager`/`devEngines.packageManager` says npm. setup-python caches nothing by default. |
| **Always misses on main** | Key has `sha`/`run_id`/a date and no `restore-keys`. `hashFiles` covers files the build generates. `path` differs between save and restore. The job usually fails, so nothing is saved. Only PR runs save. Read-only trigger. Evicted within the hour (thrashing). |
| **Always hits but stale** | Key has no lockfile hash, or `hashFiles` returned `''`, so the key is constant. Immutability then freezes the first contents. |
| **Too big** | Restore time ≈ cold rebuild. CircleCI heuristic: most dependency caches are under 300 MB; if P50 restore is over 15 s, time a cold install ([CircleCI](https://circleci.com/docs/guides/optimize/caching/)). |
| **Thrashing** | `usage` at the limit. Many `refs/pull/*` entries. Default-branch keys with recent `createdAt` but unchanged inputs. Oldest `lastAccessedAt` under 7 days (size-driven eviction). Hundreds of `buildkit-blob-*` keys. |

---

## 3. Canonical fixes

**A. Restore everywhere, save only from the default branch.** This is the main fix for quota churn.
- Detect: §2.4 shows many `refs/pull/*` MB, or main misses.
- Good: only `refs/heads/<default>` holds dependency caches.
```yaml
- uses: actions/cache/restore@v6
  id: c
  with:
    path: ~/.npm
    key: npm-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('package-lock.json') }}
    restore-keys: npm-${{ runner.os }}-${{ runner.arch }}-
- run: npm ci
- uses: actions/cache/save@v6
  if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch) && steps.c.outputs.cache-hit != 'true'
  with:
    path: ~/.npm
    key: ${{ steps.c.outputs.cache-primary-key }}
```
- Alternatives:
  - `cache-mode: read` on PR-only workflows. This also blocks the setup-* saves, but with toolkit < 6.2 the archive is still built before the denial (§1.4).
  - setup-java v6 `cache-read-only: true`.
  - setup-gradle, which by default writes only from the default branch ([setup-gradle](https://github.com/gradle/actions/blob/main/docs/setup-gradle.md)).
  - pnpm/setup `save-cache: false` (store only: the lockfile-verification cache and, since v3.2.0, the pnpm executable cache are still saved).
  - setup-uv `save-cache: false`.
  - setup-node has no save toggle. Use `package-manager-cache: false` plus a manual `actions/cache/restore` ([advanced usage](https://github.com/actions/setup-node/blob/main/docs/advanced-usage.md)).
- Preconditions: the default branch must run the job on `push` or `schedule`, otherwise nothing seeds the cache.
- Gain: main's hit rate recovers on repos near quota. *Typical, unmeasured.*
- Risk: PRs that change the lockfile get only a partial restore.

**B. Delete PR caches on close.** Adapted from the [manage-caches docs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manage-caches). Fork PRs need `pull_request_target`, and its security caveats apply. From 2026-12-02 public repos block `pull_request_target` by default unless an Actions event policy allows it ([changelog](https://github.blog/changelog/2026-11-02-pull_request_target-blocked-by-default-december-2/)).
```yaml
on: { pull_request: { types: [closed] } }
permissions: { actions: write }
jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - run: gh cache delete --all --ref "refs/pull/${{ github.event.pull_request.number }}/merge" --succeed-on-no-caches
        env: { GH_TOKEN: "${{ github.token }}", GH_REPO: "${{ github.repository }}" }
```
`--all --ref` needs gh ≥ 2.86.0 ([cli release](https://github.com/cli/cli/releases/tag/v2.86.0)). On older gh, loop over `gh cache list --ref … --json id` as the docs do.

**C. Build once, share across jobs.**
- Within one run, prefer `actions/upload-artifact`/`download-artifact`: no cache quota, no eviction.
- If you use the cache instead, save with key `x-${{ github.sha }}` and restore with `fail-on-cache-miss: true` ([restore README](https://github.com/actions/cache/blob/main/restore/README.md)).

---

## 4. setup-* built-in caches
| Action | Enable | Caches | Key / gotchas |
|---|---|---|---|
| setup-python v7 | `cache: pip\|pipenv\|poetry`, off by default | pip: the global cache (packages are still installed every run). pipenv/poetry: the virtualenv(s) ([README](https://github.com/actions/setup-python)) | No uv support: use `astral-sh/setup-uv` (§5). |
| setup-go v7 | on by default; `cache: false` disables | module + build cache | **Since v6 the key hashes `go.mod`, not `go.sum`** ([README](https://github.com/actions/setup-go)). GitHub's docs table still says go.sum. Set `cache-dependency-path: go.sum` for precision. No restore-keys. |
| setup-java v6 | `cache: maven\|gradle\|sbt` | `~/.m2/repository`, `~/.gradle/caches`, wrappers separately, and the JDK (`cache-jdk`, on when `cache` is set) | `setup-java-<os>-<arch>-<id>-<hash>`. v6 adds `cache-read-only`, `cache-path`, and the `cache-primary-key` output ([README](https://github.com/actions/setup-java)). For Gradle prefer setup-gradle. |
| gradle/actions/setup-gradle v6 | on by default | Gradle User Home | Read-only off the default branch. The default `cache-provider: enhanced` is proprietary: free for public repos, a "Free Preview" for private ones. `basic` is MIT. Don't combine with setup-java `cache: gradle` ([docs](https://github.com/gradle/actions/blob/main/docs/setup-gradle.md)). |

setup-node v7 caching (npm, yarn, pnpm): see [stack/node-pm.md](stack/node-pm.md) checks 2–3 and its action keys.

---

## 5. Package managers and the node_modules trade-off
- **npm, pnpm, Yarn Berry, Bun:** cache paths, setup actions and frozen installs: see [stack/node-pm.md](stack/node-pm.md) (Checks 1–3, Cache paths).
- **uv:**
  - setup-uv v10 `enable-cache` defaults to **`auto`**: on for GitHub-hosted runners, except release, tag push, `pull_request_target` and `workflow_run`.
  - `prune-cache` defaults to `false` ([action.yml](https://github.com/astral-sh/setup-uv/blob/main/action.yml)).
  - With a manual cache, run `uv cache prune --ci` before the save ([uv docs](https://docs.astral.sh/uv/guides/integration/github/)).
- **Caching `node_modules` directly:** actions/cache examples say it is "not recommended", because it breaks across Node versions and doesn't work with `npm ci`. Only do it like this:
  ```yaml
  - uses: actions/setup-node@v7
    id: node
    with: { node-version-file: .nvmrc }
  - uses: actions/cache@v6
    id: nm
    with:
      path: node_modules            # monorepo: '**/node_modules' (slow to tar)
      key: nm-${{ runner.os }}-${{ runner.arch }}-node${{ steps.node.outputs.node-version }}-${{ hashFiles('package-lock.json') }}
      # NO restore-keys: a partial node_modules is wrong state
  - if: steps.nm.outputs.cache-hit != 'true'
    run: npm ci
  ```
  - Risks:
    - Native addons are tied to the Node ABI.
    - Postinstall downloads outside the tree are not captured (`~/.cache/ms-playwright`, the Cypress binary).
    - It is usually larger than the store.
    - Under fix A, lockfile-changing PRs get nothing.
  - Gain: install time minus restore time. Measure both.

---

## 6. Tool caches
Per-tool paths, keys and restore order are in the stack files, each under "Cache paths": [typescript](stack/typescript.md) (`*.tsbuildinfo`), [lint](stack/lint.md) (ESLint `--cache`), [vitest](stack/vitest.md), [jest](stack/jest.md), [nextjs](stack/nextjs.md) (`.next/cache`), [turbo](stack/turbo.md), [nx](stack/nx.md), [playwright](stack/playwright.md) (browsers), [docker](stack/docker.md) (buildx), [go](stack/go.md) (`GOCACHE`, module cache), [rust](stack/rust.md) (`~/.cargo`, `target`, sccache), [python](stack/python.md) (uv, pip, mypy), [gradle](stack/gradle.md) (Gradle User Home, build and configuration cache) and [maven](stack/maven.md) (`~/.m2`, build cache extension).

| Tool | Path | Key | Notes |
|---|---|---|---|
| Maven/Gradle (manual) | `~/.m2/repository` keyed on `**/pom.xml`. Gradle: `~/.gradle/caches` + `~/.gradle/wrapper` keyed on `**/*.gradle*`, `**/gradle-wrapper.properties` | as left | Stop Gradle daemons before the save, because held locks break archiving ([examples](https://github.com/actions/cache/blob/main/examples.md)). |

---

## 7. Anti-patterns → fix
1. `key: ${{ runner.os }}-deps`: a constant key freezes the first save forever. **Fix:** add `hashFiles('<lockfile>')`.
2. `hashFiles('app/package-lock.json')` when the file is at the root: returns `''`, so the key is constant. **Fix:** check the key in the log, and fail the job if it ends in `-`.
3. `key: build-${{ github.sha }}` without `restore-keys`: always misses and writes a new entry every run.
4. `hashFiles('**/*.ts')` in big repos: slow, and may hit the 120 s runner timeout. **Fix:** hash lockfiles and configs, and use `github.sha` plus prefix restore for build caches.
5. Restoring `node_modules` and then running `npm ci`: see [stack/node-pm.md](stack/node-pm.md) check 10.
6. `restore-keys` on `node_modules`, or on outputs that are unsafe to reuse partially.
7. Double caching: setup-node `cache: npm` **and** `actions/cache` on `~/.npm`, or setup-java `cache: gradle` **and** setup-gradle.
8. Saving from every PR: fills `refs/pull/*` and evicts main's entries (hourly). **Fix:** fix A plus fix B.
9. Matrix over OS or arch without `runner.os`/`runner.arch` in the key: x64 and arm64 restore each other's native binaries, because arch is not part of the cache version.
10. Caching `~`, `~/.cache` or the workspace: huge archives that are slower than a rebuild.
11. Several Docker images on the default gha `scope`: see [stack/docker.md](stack/docker.md) check 4.
12. Playwright browser-cache keying and `install-deps`: see [stack/playwright.md](stack/playwright.md) Cache paths.
13. ESLint `--cache` strategy and typed rules in CI: see [stack/lint.md](stack/lint.md) L1.
14. Writing caches from `pull_request_target`/`issue_comment` (`cache-mode: write`), or release/publish jobs restoring shared caches. This is cache poisoning: "Cache contents are not signed or verified" ([docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)). **Fix:** `cache-mode: none` or a cold install for release jobs.
15. `actions/cache@v1/v2`, pins below `v3.4.0`/`v4.2.0` (fail since 2025-03-01), or `save-always: true` (deprecated, broken).

---

## 8. Fix priority
| Fix | Gain | Preconditions / risk |
|---|---|---|
| Add a package-manager cache | The download share of install; *typical, unmeasured* | Lockfile committed. Can be a net loss with a fast registry and a large cache ([pnpm](https://pnpm.io/continuous-integration)). |
| Save only on main + PR cleanup | Restores main's hit rate near quota; *typical, unmeasured* | Default branch runs on `push`. PRs restore main's last entry. |
| Next/Turbo/Nx/TS/ESLint/Vitest caches | Proportional to the share of unchanged work; *unmeasured* | Tool version in the key. Output must equal a cold run. |
| Remove a cache | Restore + save time, when restore ≥ rebuild | Confirm with the step timings from §2.3. |

Docker layer cache (`mode=max`, per-image `scope`, or registry cache): see [stack/docker.md](stack/docker.md) checks 4–5.

---

## 9. Other CIs
| Concept | GitHub Actions | GitLab CI | CircleCI |
|---|---|---|---|
| Content-hash key | `hashFiles()` | `cache:key:files` | `{{ checksum "file" }}` |
| Fallback | `restore-keys` (prefix, newest) | `fallback_keys` (≤ 5), then `CACHE_FALLBACK_KEY` | key list, prefix, most recent |
| Restore-only | `cache/restore`, `cache-mode: read` | `policy: pull` | `restore_cache` only |
| Mutability | Immutable | Default `pull-push` uploads changes at job end; same key = overwrite | Immutable: "you cannot overwrite it" |
| Isolation | branch + default + base | `-protected` / `-non_protected` suffix (setting) | none |
| Retention / size | 7 d since last access; 10 GB default | Runner-local unless a distributed (S3) cache is set up | 15 d max; no size cap, but restore time grows |

Sources: [GitLab caching](https://docs.gitlab.com/ci/caching/), [GitLab `cache:policy`](https://docs.gitlab.com/ci/yaml/#cachepolicy), [CircleCI caching](https://circleci.com/docs/guides/optimize/caching/).

Portable rules:
- Key on lockfile + tool version + OS/arch.
- Use prefix fallbacks only for download and tool caches, never for installed trees.
- Write caches only from trusted, protected-branch pipelines.
- Measure restore time against cold time.
- On autoscaled runners, use a distributed cache. Otherwise GitLab only hits when a job lands on the same runner.
