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

Count distinct identifiers across stored contribution records with `bundle exec rake swhids:contributions`. The task reports a total and separate revision and directory counts, using a PostgreSQL aggregate without loading projects into Ruby. It makes no archive requests. These counts mean "archived after our request"; another archive process could have handled the same objects concurrently, and historical contributions cannot be reconstructed from earlier coverage checks.

Repository coverage is stored separately in `swhids.origin_archive`. `SwhidOriginChecker` reads [Software Heritage's origin visit history](https://docs.softwareheritage.org/devel/swh-web/uri-scheme-api-origin.html) to find an archived snapshot at any version. It checks the source URL, repository metadata, known aliases, previous names, and `.git` URL variants. A full or partial visit with a snapshot counts as coverage. A registered origin or failed visit without a snapshot does not establish coverage. Lookups retain the URLs checked, visit dates, snapshot identifiers, and errors.

Before submitting missing objects, the archiver checks repository coverage and copies the evidence into `swhids.archival.repository_before_request`. `missing_versions` means a snapshot was found; `missing_repository` means no snapshot was found at the checked URLs. Unknown URLs outside that set may still have archived copies. Errors and incomplete checks produce `unknown`. Later imports preserve a known pre-submission classification; unknown cases can gain a classification based on visit history. Rate limits postpone submission, while other lookup errors permit submission with an unknown classification.

Existing requests can gain a `missing_versions` classification when visit history contains a snapshot dated before their submission. This is an inference from visit history; the report distinguishes its `visit_history` basis from `pre_submission` observations. Existing requests without earlier evidence remain unknown, including when no snapshot is found today. An origin visit date alone does not record when its snapshot became available.

Run `bundle exec rake swhids:coverage` for counts across eligible projects. The report includes repository coverage, submitted projects, imported projects, and the evidence used to classify submissions. Submitted and imported counts include only requests attributed to Science, excluding reused requests and attempts without an SWH request ID. These are project counts. `repository_coverage.not_found` means no snapshot found at the checked URLs; `unknown` means an inconclusive check, and `unchecked` means no repository lookup has been recorded. Exact revision and directory coverage remains separate.

To backfill existing submissions in a bounded page:

```sh
bundle exec rake swhids:check_origins REQUESTS_ONLY=true LIMIT=100 AFTER_ID=0
```

The task prints `last_project_id`; use that value as `AFTER_ID` for the next page. Omit `REQUESTS_ONLY=true` to include all eligible projects, even those awaiting a local SWHID scan. Origin checks do not clone repositories or request archival. Later local scans preserve the recorded repository coverage. The task's default limit is 100 and maximum is 1,000. Jobs use the `swh_api` queue and shared API cooldown.

Successful repository lookups are cached for seven days, unknown results for an hour. Pre-submission observations have a five-minute freshness window, and retries refresh successful observations. A completed archival request queues a fresh repository check while preserving its pre-submission evidence. Each check is limited to eight candidate URLs, three visit pages per URL, and ten HTTP requests overall. Exhausting those limits preserves unknown coverage unless a snapshot has already been found. These origin lookups are individual API requests, separate from the bulk identifier checks.

The client sends `User-Agent: science.ecosyste.ms (+https://science.ecosyste.ms)`. Anonymous access works for coverage checks; set `SWH_API_TOKEN` to send an optional Software Heritage bearer token. Rate-limit exemptions depend on the account's permissions. Tokens are not stored in project results.

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
