# SWHIDs

Project sync queues `RepositoryScanWorker` after updating Science Score when a scientific project needs SWHID calculation. Eligible projects are visible, have repository metadata, and meet the scientific threshold of 20. The worker uses the `swhid` queue and rechecks eligibility and saved results before scanning. Projects with stored identifiers send due archive checks directly to the API queue.

Each worker process reserves one thread for the `swh_api` queue, which handles bulk coverage checks, repository lookups, and archival requests. The other nine threads process the existing queues, for a total concurrency of ten per process. The shared API cooldown still applies across all processes.

The worker clones the current default branch once, then uses that checkout for SWHIDs, metadata provenance, and Brief when those analyses are due. It stores the revision and checkout-directory identifiers in `projects.swhids`. Each command has a 120-second timeout, and the temporary checkout is removed after processing. A per-project database lock prevents concurrent workers from cloning the same project. The Docker image installs the `swhid-go` v0.1.0 CLI as `swhid`; local workers also need that executable on `PATH`.

The stored result includes the clone origin, commit, attempt time, analysis duration, and separate `revision` and `directory` results. Each calculation records its SWHID, binary version, argument array, input identity, method, duration, and status. Errors are limited to 500 characters. As with Brief, stored successes and calculation errors prevent automatic rescanning; clear `swhids` to request another attempt. Unexpected job errors have three Sidekiq retries. SWHID results do not affect Science Score; Brief results can update it during the same job. Tags and releases are not scanned.

After calculation, the worker adds the project to a shared pending set in Redis. `CheckSwhidBatchWorker` waits 30 seconds to collect work, then checks up to 500 projects with one `POST /api/1/known/` request. Each project contributes at most a revision and a directory, within the API's limit of 1,000 identifiers. Shared identifiers are sent once. Repeated jobs add only one pending entry per project, and only one batch job can be waiting at a time. A PostgreSQL advisory lock prevents concurrent batch requests; remaining work schedules another batch after 30 seconds. Pending entries are retained until their results have been processed.

Each object's `archive` field records `archived` or `not_found` with `checked_at`. Lookups are cached for seven days. HTTP, transport, and invalid-response errors record `error` with `attempted_at` and become eligible after an hour. Normal project sync queues due checks, including for previously calculated identifiers, without cloning the repository again. Batch results preserve archival evidence and skip objects changed by a concurrent scan or check. Page requests read the stored result.

Missing objects queue `CheckSwhidArchivalWorker` to submit a Git origin save request. The pre-request lookup must be successful and less than five minutes old; older results are checked again. The worker stores the missing identifiers and their lookup timestamps in `swhids.archival.before_request` before submitting to Software Heritage. It then stores the returned request ID and status. `CheckSwhidArchivalWorker` follows pending requests every six hours for up to 30 days, on the `swh_api` queue. A successful save task triggers another lookup of the exact identifiers. These pre-submission and confirmation checks remain per project.

`swhids.archival.confirmed_swhids` records previously missing objects found after the save task succeeds. Requests dated before our submission are excluded from attribution, as the API may return an existing request. Failed or rejected requests do not count. A submission with an uncertain outcome is retained without automatic resubmission; failed follow-up lookups retry the existing request. Coverage refreshes preserve the request evidence and each object's first recorded successful lookup. Clearing `swhids` also clears this evidence.

HTTP 429 responses defer API calls until `Retry-After`, accepting either seconds or an HTTP date. Missing or invalid headers use a one-hour delay, and retries wait at least a minute. The production cache shares this pause between workers. Jobs are scheduled with up to five minutes of additional random delay; workers do not sleep while waiting. This applies to coverage lookups, origin submissions, and request polling.

A rate-limited batch retains its pending projects and schedules one shared retry. New coverage checks join that pending set during the cooldown. Local cloning and SWHID calculation continue while API calls are paused.

Rejected submissions record `rate_limited` and retry after checking coverage again. Objects that became known during the wait are excluded from the new request; if all are known, the request becomes `not_needed`. A polling rate limit retains the accepted request ID. Older records with `status: uncertain`, `error: HTTP 429`, and no request ID can also retry when their worker runs. Other uncertain outcomes are not automatically resubmitted.

Run `bundle exec rake swhids:contributions` for a readable report of eligible science projects, the number and percentage with new archival requests and successful imports, repository coverage, and the missing-version versus missing-repository breakdown. The report separates observations made before submission from inferences based on historical visit dates. It also counts distinct confirmed SWHIDs across all recorded projects, including projects that are no longer eligible, with separate revision and directory totals. All counts use stored database records; the task makes no archive requests or queues new work. These identifier counts mean "archived after our request"; another archive process could have handled the same objects concurrently, and historical contributions cannot be reconstructed from earlier coverage checks.

Repository coverage is stored separately in `swhids.origin_archive`. `SwhidOriginChecker` reads [Software Heritage's origin visit history](https://docs.softwareheritage.org/devel/swh-web/uri-scheme-api-origin.html) to find an archived snapshot at any version. It checks the source URL, repository metadata, known aliases, previous names, and `.git` URL variants. A full or partial visit with a snapshot counts as coverage. A registered origin or failed visit without a snapshot does not establish coverage. Lookups retain the URLs checked, visit dates, snapshot identifiers, and errors.

Each origin observation stores `latest_attempt`, the newest observed archive visit regardless of status, separately from `visit`, the newest full or partial visit with a snapshot. Both retain the origin URL, visit date and status. A failed attempt yesterday can therefore appear alongside a snapshot-bearing visit from last year. Visit dates describe archive visits; they do not measure commit ingestion lag or establish how recent the captured source content is.

`current_origins` lists candidates matching the stored `repository_url` at the time of the check, including unchecked candidates. Observations have `origin_role: current` or `other`; the latter includes former names and other candidate URLs. Matching permits transport and `.git` variants, with case-insensitive paths on GitHub and case-preserving paths on other hosts. A recent visit at a former URL does not establish current-origin freshness. If a project URL changes, existing roles remain tied to the recorded `repository_url` until another check runs.

Before submitting missing objects, the archiver checks repository coverage and copies the evidence into `swhids.archival.repository_before_request`. `missing_versions` means a snapshot was found; `missing_repository` means no snapshot was found at the checked URLs. Unknown URLs outside that set may still have archived copies. Errors and incomplete checks produce `unknown`. Later imports preserve a known pre-submission classification; unknown cases can gain a classification based on visit history. Rate limits postpone submission, while other lookup errors permit submission with an unknown classification.

Existing requests can gain a `missing_versions` classification when visit history contains a snapshot dated before their submission. This is an inference from visit history; the report distinguishes its `visit_history` basis from `pre_submission` observations. Existing requests without earlier evidence remain unknown, including when no snapshot is found today. An origin visit date alone does not record when its snapshot became available.

Run `bundle exec rake swhids:coverage` for counts across eligible projects. The report includes repository coverage, submitted projects, imported projects, and the evidence used to classify submissions. Submitted and imported counts include only requests attributed to Science, excluding reused requests and attempts without an SWH request ID. These are project counts. `repository_coverage.not_found` means no snapshot found at the checked URLs; `unknown` means an inconclusive check, and `unchecked` means no repository lookup has been recorded. Exact revision and directory coverage remains separate.

To backfill existing submissions in a bounded page:

```sh
bundle exec rake swhids:check_origins REQUESTS_ONLY=true LIMIT=100 AFTER_ID=0
```

The task prints `last_project_id`; use that value as `AFTER_ID` for the next page. Omit `REQUESTS_ONLY=true` to include all eligible projects, even those awaiting a local SWHID scan. Origin checks do not clone repositories or request archival. Later local scans preserve the recorded repository coverage. The task's default limit is 100 and maximum is 1,000. Jobs use the `swh_api` queue and shared API cooldown.

Completed origin lookups are cached for seven days. Unfinished checks become eligible after an hour; a rate limit uses the shared API cooldown instead. Each run checks up to eight candidate URLs, three visit pages per URL, and ten HTTP requests overall. Later runs try untried URLs first, then resume incomplete lookups in order of their last attempt, before refreshing stale completed observations. Queue another check through `swhids:check_origins` to continue a bounded lookup; rate-limited workers schedule their own retry. These origin lookups are individual API requests, separate from the bulk identifier checks.

Each observation retains its own `attempted_at` and, after a completed lookup, `checked_at`. Interrupted pagination saves `next_visit`, the next `last_visit` cursor. `lookup_complete` means the lookup found sufficient snapshot evidence or exhausted history; `history_complete` means history was exhausted. A snapshot can finish a coverage lookup before all pages or URLs have been read. `complete` records whether all candidate lookups are complete, and `unchecked_origins` lists URLs without an attempt. The top-level `checked_at` dates the saved batch and does not refresh older observations. These progress fields are also returned by the stored-evidence API; older records can omit them.

`latest_attempt_checked_at` records when an origin's first visit-history page was read successfully. Software Heritage returns visits by descending date, so `freshness_complete` becomes true for that origin once a scan from the first page finds a snapshot or reaches the end of history. Older pages can remain unread after a snapshot is found. If history stops before a snapshot is found, the latest attempt is retained but snapshot freshness remains incomplete. Failed refreshes retain earlier visit evidence and timestamps. The top-level `freshness_complete` requires this check for every candidate; observations can have different dates, and no single date is presented as the newest across unchecked URLs.

To continue through remaining aliases after finding coverage, queue a bounded freshness pass:

```sh
bundle exec rake swhids:check_origins FRESHNESS=true LIMIT=100 AFTER_ID=0
```

Freshness passes use the same per-run limits and shared cooldown. Requeue an unfinished batch after its `freshness_retry_at` to continue from saved progress; rate-limited workers retain freshness mode in their scheduled retry. Completed freshness checks become eligible again after seven days. Older observations without freshness fields are checked lazily, and a freshness pass restarts legacy pagination when the first-page observation date is unknown. These read-only passes do not submit archival requests or replace known pre-submission classifications.

Candidate changes retain observations for exact URL matches, drop removed candidates, and give new URLs priority. Known URL spellings are preserved. Refreshes restart completed lookups at the first page, while failed refreshes retain earlier evidence and its timestamp. Pre-submission observations have a five-minute freshness window, checked against each retained observation. A completed archival request queues a forced repository check while preserving its pre-submission evidence. Historical lookups retain their submission cutoff and restart pagination if that cutoff changes. Concurrent coverage or candidate changes prevent an older run from replacing the newer saved state.

The client sends `User-Agent: science.ecosyste.ms (+https://science.ecosyste.ms)`. Anonymous access works for coverage checks; set `SWH_API_TOKEN` to send an optional Software Heritage bearer token. Rate-limit exemptions depend on the account's permissions. Tokens are not stored in project results.

Optional ancestor checks run separately from routine scans. Queue projects that already have successful current-revision and repository-origin lookups:

```sh
bundle exec rake swhids:check_history LIMIT=100 AFTER_ID=0
```

The task accepts up to 1,000 projects and prints `last_project_id` for the next page. It groups projects into jobs of at most ten so shared ancestor identifiers can be checked once per API batch. `CheckSwhidHistoryWorker` fetches history on the `swhid` queue; `CheckSwhidHistoryBatchWorker` checks identifiers on `swh_api` through the existing batch client and shared cooldown. Neither worker requests archival. To queue a single eligible project:

```ruby
puts "job_id: #{CheckSwhidHistoryWorker.perform_async([476]).inspect}"; nil
```

The first run pins the commit and origin recorded in `projects.swhids`. Each fetch requests that exact commit, even if the default branch advances. A bare temporary repository avoids a working-tree checkout and requests blob filtering. Ancestor revision SWHIDs use [Git's SHA-1 commit identifiers](https://docs.softwareheritage.org/devel/swh-model/persistent-identifiers.html); the current revision and directory scanner continues to use `swhid-go`. SHA-256 commits are recorded as unsupported.

Each project starts with a fetch depth of 100, increasing by 100 on later runs up to 1,000. A search retains at most 1,000 distinct ancestors and checks at most 100 pending identifiers per API job. Git commands share a 120-second deadline per project. Temporary repository size is checked every 0.1 seconds against a 500 MB threshold; this is a monitored limit, so transfers can overshoot between checks. A server that ignores blob filtering is subject to the same limit. Temporary repositories are removed after success or failure.

Progress is stored in `swhids.history_archive` and returned by `GET /api/v1/projects/:id/swhids`. It includes `starting_commit`, requested `depth`, inspected `revisions`, per-revision lookup dates, and `checked_count`. `history_complete` means Git ancestry was exhausted; `complete` also requires successful lookups for every ancestor. Thus a complete search with no archived ancestors differs from a truncated or failed search. For A-B-C, with B archived and C missing, B appears in the historical results while C's existing coverage stays missing. The API excludes temporary paths and Git error text.

Queue the same project IDs again to resume. Pending identifiers are checked before fetching deeper history, and successful ancestor lookups retain their original dates. Rate limits schedule an API-only retry; other failures and unfinished batches require another explicit queue request. Depth and identifier caps leave the search incomplete. Completed and unsupported searches are skipped. Later repository scans preserve historical results with their original starting commit; to start a new search, remove only `history_archive` from the project's stored SWHID data before requeuing. Clearing all `swhids` removes every kind of archive evidence.

Inspect a saved result in the Rails console:

```ruby
project = Project.find(476); pp project.swhids; nil
```

Queue one eligible project from a Rails console:

```ruby
project = Project.find(476); puts "job_id: #{project.fetch_swhids_async.inspect}"; nil
```

Local archive experiments can call the calculator from a Rails console without changing project records:

```ruby
pp SwhidCalculator.new.calculate(type: "directory", path: "/tmp/extracted/source", artifact: "/tmp/source.tar.gz"); nil
```

`artifact` records the archive's SHA-256 beside the extracted-directory SWHID. The caller supplies the extracted path; the calculator does not download, extract, or normalize archives, or verify that the directory came from that artifact. Record extraction choices alongside the output when comparing archives.

Directory calculation hashes the checkout or extracted filesystem using the CLI's handling of Git index modes and symlinks. Checkout filters can change file contents relative to Git's stored tree, so a successful origin save does not establish coverage of every calculated directory. Contributions require confirmation of the exact SWHID.

The worker tests normally stub HTTP responses. Set `SWH_LIVE_TEST=true` when running `test/sidekiq/check_swhid_origin_worker_test.rb`, `test/sidekiq/check_swhid_batch_worker_test.rb`, `test/sidekiq/swhid_archive_check_test.rb`, or `test/sidekiq/swhid_archival_test.rb` to include live checks of orbdot's visit history, archived objects, and an existing save request. These live tests do not submit an archival request.
