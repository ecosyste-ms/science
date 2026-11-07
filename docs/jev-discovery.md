# Jev discovery

Jev discovery stores evidence in `jev_runs`, `jev_discoveries` and `jev_requests`. It does not update projects, Science Score, inclusion thresholds or catalogue membership. Ordinary sync and API requests do not call Jev. `/discovery-review` requires the existing Sidekiq operator credentials and records research, negative or uncertain reviews without publishing a project.

Each run samples visible projects scoring zero and below 20, unscored projects, unlinked stored packages and absent non-fork repositories from repos.ecosyste.ms. The intended local shares are 25%, 20%, 5% and 25%; external repository pages fill the remainder. Each candidate records its source, sample group, sampling method and page provenance. Existing projects and aliases are excluded from the absent-repository sample, including hidden records.

Local strata use seeded hash ordering of IDs. Package sampling filters supported HTTPS hosts and obvious existing repository matches before selection, then checks normalized URLs and aliases again. External sampling uses seeded page and ascending/descending name order within the API's 100-page limit. That frame covers names near the ends of the namespace and has uneven coverage. Results describe the sampled frame, not the entire repository population. Unsupported repository hosts are skipped. Sampling errors are recorded while already sampled work continues.

The strict research question runs against stored metadata first. Strict probability at least 0.6 selects enrichment; deterministic random controls select 20% of the borderline band (above 0.2 and below 0.6) and 5% of the low band. Selection probabilities are stored. Enrichment waits for sampling and screening to finish, then orders controls first and candidates by seeded hash, so early source groups cannot consume the cap before later groups are screened. The run enrichment cap can defer selected candidates, so analysis must also account for deferred records and completed enrichment counts within each stratum.

Enrichment collects up to 8,000 README characters, 80 source paths, Brief language names and line counts through bounded partial checkouts. Brief uses the installed SCC line counter; both tools are included in the production image and CI. Repository code is never executed. No full Brief outlines or generated summaries are supplied. The implementation question retains its own probability. At least 0.8 routes a result to the research review queue without a second 0.8 requirement on the strict answer. A low strict answer and low or absent implementation answer routes to negatives. Everything else is uncertain. These are review labels, not calibrated probabilities of catalogue eligibility. Checkout failures and incomplete evidence remain visible.

Successful identical inputs, questions and model releases share cached responses across runs. Questions have content fingerprints; requests retain inputs, outputs, attempts, token usage, latency and estimated charges. Failed attempts belong to the run that paid for them. Requests reserve a conservative charge before transmission, and unknown outcomes retain that reservation. Reported spend uses the [provider's pricing](https://help.typesafe.ai/articles/5187202169-how-much-does-jev-cost), checked on 7 November 2026: $0.042 per million input tokens with free output. It excludes repository fetching, compute and review. Check provider billing when changing model or pricing.

Set `JEV_API_KEY` through the deployment environment and enable `JEV_ENABLED=true`. It defaults off. Do not put the key in commands, logs or tracked files. The scheduler runs once per minute and uses dedicated `jev` and `jev_enrich` Sidekiq capsules. Redis limits apply across all worker processes. The following settings are available:

| Setting | Default | Purpose |
| --- | --- | --- |
| `JEV_MODEL` | `jev-1.14.0` | Pinned Jev release |
| `JEV_BATCH_SIZE` | 500 | Maximum queued metadata screens per run |
| `JEV_ENRICH_BATCH_SIZE` | 20 | Maximum queued repository enrichments per run |
| `JEV_MAX_ENRICHMENTS` | 1000 | Total enriched candidates per run |
| `JEV_CONCURRENCY` | 2 | Global in-flight Jev requests |
| `JEV_REQUESTS_PER_SECOND` | 5 | Global request rate |
| `JEV_ENRICH_CONCURRENCY` | 1 | Global repository checkouts |
| `JEV_TOTAL_BUDGET_USD` | 5 | Lifetime spend plus reservations across runs |
| `JEV_MAX_ATTEMPTS` | 3 | Attempts per candidate and stage |
| `JEV_RETRY_SECONDS` | 60 | Initial exponential retry delay |
| `JEV_DISK_LIMIT_MB` | 200 | Checkout disk ceiling |
| `JEV_RESCAN_DAYS` | 7 | Interval for checking completed evidence |

Run settings are copied at creation. Rate, concurrency, disk and global budget settings are read at execution. Available Sidekiq threads also bound concurrency. Run budgets include reservations; credit, authentication and budget failures pause the run. Leases recover interrupted workers. Failed work remains inspectable after retries are exhausted. Pause stops new work; already active calls can finish.

The local Dokku client supplies this application's name. Start a controlled run and inspect it with:

```sh
dokku run env NAME=initial-discovery TARGET=10000 BUDGET_USD=1 bundle exec rake jev:start
dokku run env RUN_ID=1 bundle exec rake jev:status
dokku run bundle exec rake jev:tick
```

Replace `RUN_ID` with the returned ID. Status includes processing and classification counts, source groups, control bands, reviews, request errors, tokens, estimated spending, reservations, latency and throughput. The authenticated review queue supports run, probability-band, classification, sample-group, review-state, repository and control filters.

```sh
dokku run env RUN_ID=1 bundle exec rake jev:pause
dokku run env RUN_ID=1 bundle exec rake jev:resume
dokku run env RUN_ID=1 bundle exec rake jev:retry
dokku run env RUN_ID=1 LIMIT=20 bundle exec rake jev:retry_evidence
dokku run env RUN_ID=1 bundle exec rake jev:reevaluate
```

`retry` resets failed stage attempts. `retry_evidence` clears cached incomplete source collections for a bounded number of completed candidates and queues fresh enrichment. It retains the earlier request ID, source revision and error in collection history; identical resulting model inputs still use the request cache. Checkout errors distinguish unavailable repositories, missing revisions, timeouts, disk/output limits and rate limits, and successful collections record duration in milliseconds. Resume after fixing credentials or increasing the budget within the intended spending limit. `reevaluate` adopts the current model and question fingerprints, invalidates active leases and clears current probabilities and review status. Unchanged successful requests are cached. Old request records and review notes remain stored; detailed review history is not versioned. Use a new named run when preserving an earlier evaluation cohort matters.

Completed records are checked incrementally for changed metadata, repository push revision, stored README or Brief statistics and changed question content. The run retains its pinned model until explicit re-evaluation or a new run. Source evidence is recollected when its fingerprint changes. Checks use existing stored project evidence and repository API snapshots, so changes that upstream sources have not indexed remain undetected.

For evaluation, review a seeded sample within each source and screen band, including low controls, deferred enrichment and failures. Report supported discoveries per 100 reviewed, uncertainty and misses separately. Compare both probabilities on the same reviewed repositories. Repeat near-threshold requests with distinct `replicate` values through `JevClient#call` to measure stability without replacing the main result. Store those request IDs and the review sampling frame with the report. Do not extrapolate high-probability review precision across the full corpus or expand scans solely because requests are cheap.
