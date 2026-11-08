# Jev discovery

Jev discovery stores evidence in `jev_runs`, `jev_discoveries` and `jev_requests`. It does not update projects, Science Score, inclusion thresholds or catalogue membership. Ordinary sync and API requests do not call Jev. `/discovery-review` requires the existing Sidekiq operator credentials and records research, negative or uncertain reviews without publishing a project.

Each run samples visible projects scoring zero and below 20, unscored projects, unlinked stored packages and absent non-fork repositories from repos.ecosyste.ms. The intended local shares are 25%, 20%, 5% and 25%; external repository pages fill the remainder. Each candidate records its source, sample group, sampling method and page provenance. Existing projects and aliases are excluded from the absent-repository sample, including hidden records.

Local strata use seeded hash ordering of IDs. Package sampling filters supported HTTPS hosts and obvious existing repository matches before selection, then checks normalized URLs and aliases again. New runs sample external repositories through seeded time cutoffs in the host's indexed owner creation dates. Each window chooses three of the next 20 owners without research-keyword or institution filters, then up to ten of 100 non-fork repositories per owner, alternating seeded earliest/latest repository creation order. The host date range is frozen at the start, and owner/window checkpoints and provenance are stored. This covers more of the owner namespace, but temporal density, owner clustering and repository caps make it an unequal sample. Results do not estimate corpus prevalence. Runs created without the `external_sampling` setting retain their original name-page frame for reproducibility.

Workers normally exclude existing projects at or above the Science Score threshold. An evaluation run can set `run.update!(settings: run.settings.merge("include_scored_projects" => true))` to screen already included projects as reference cases. This permits comparison with general-purpose or unrelated software that Science Score includes. Hidden projects remain excluded, and no score or catalogue record changes. This setting affects processing of seeded candidates; it does not add included projects to the default sample. Previously excluded reference cases must be explicitly requeued within that run.

Owner sampling processes three owner steps per scheduler tick and stops at the configured window limit if the target cannot be filled. Unavailable owners are skipped; other owner repository failures retry up to the run's attempt limit before recording a skipped owner. The count and recent errors remain in sampling state. Other sampling errors remain visible while already sampled screening continues. Unsupported repository hosts are skipped.

The strict research question runs against stored metadata first. Strict probability at least 0.6 selects enrichment; deterministic random controls select 20% of the borderline band (above 0.2 and below 0.6) and 5% of the low band. Selection probabilities are stored. Enrichment waits for sampling and screening to finish, then orders controls first and candidates by seeded hash, so early source groups cannot consume the cap before later groups are screened. The run enrichment cap can defer selected candidates, so analysis must also account for deferred records and completed enrichment counts within each stratum.

Enrichment collects up to 8,000 README characters, 80 source paths, Brief language names and line counts through bounded partial checkouts. Root README files take precedence over one-level nested files, and the selected path is recorded outside model input. Paths include IDL, Cython, CUDA, Wolfram, Swift and Visual Basic files as well as the original language set. Brief uses the installed SCC line counter; both tools are included in the production image and CI. Repository code is never executed. No full Brief outlines or generated summaries are supplied. The implementation question retains its own probability. At least 0.8 routes a result to the research review queue without a second 0.8 requirement on the strict answer. A low strict answer and low or absent implementation answer routes to negatives. Everything else is uncertain. These are review labels, not calibrated probabilities of catalogue eligibility. Checkout failures and incomplete evidence remain visible.

Repository identity checks use existing project URLs, aliases and repository metadata. They distinguish a matching included project from an existing below-threshold record. README links to repositories with the same name, declared forks and copy/move statements are unconfirmed duplicate hints. Ordinary dependency links and `source_name` on non-forks do not establish an upstream. Matches and related candidates are visible in the review queue and can be filtered by identity status. No hint automatically excludes a candidate or changes either probability, review judgement or catalogue record; a missing match does not prove a distinct discovery. Identity checks use no model calls.

Application code is grouped under `Jev::`, including `Jev::Run`, `Jev::Discovery`, `Jev::Request`, services and workers. Existing table names and review URLs are unchanged.

Reviewers can record scientific purpose, implementation evidence and catalogue value independently. Each outcome has a queue filter and run counts; an unassessed outcome stays blank. Existing review notes remain available. A scientific implementation may be a distinct candidate, an already represented project, a related variant or an unresolved identity. These human review fields never change model answers, Science Score or catalogue inclusion. Rescanning changed evidence, retrying source collection and explicit re-evaluation clear current outcomes along with the overall review state.

New partial collections retain up to 40 omitted filenames and counts by filename extension for review. Historical collections with only an omission count are identified explicitly. These details are stored outside the model input and add no inference tokens. Tracked source paths can include files whose blobs were omitted, while Brief line counts describe downloaded content. The legacy `source_paths_complete` flag records whether all blobs were checked out; it does not prove that every implementation path was selected for the bounded model input. Omitted files may be data, dependencies, source or compiled artifacts, so neither an omission nor an extension establishes implementation absence.

Successful identical inputs, questions and model releases share cached responses across runs. Questions have content fingerprints; requests retain inputs, outputs, attempts, token usage, latency and estimated charges. Failed attempts belong to the run that paid for them. Requests reserve a conservative charge before transmission, and unknown outcomes retain that reservation. Reported spend uses the [provider's pricing](https://help.typesafe.ai/articles/5187202169-how-much-does-jev-cost), checked on 7 November 2026: $0.042 per million input tokens with free output. It excludes repository fetching, compute and review. Check provider billing when changing model or pricing.

New requests send recursively sorted JSON keys and retain the exact UTF-8 request text in `Jev::Request#wire_body`. The cache uses that text and the optional repeat identifier. Reloading the saved state from JSONB and repeating it therefore sends identical bytes. Older requests have no `wire_body`; their historical inputs and results remain available, but they cannot satisfy the new cache because their original key order is unknown. Re-evaluation can incur fresh inference charges even when the older parsed inputs match.

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
| `JEV_OWNER_WINDOWS` | 5000 | Maximum owner sampling windows per new run |

Run settings are copied at creation. Rate, concurrency, disk and global budget settings are read at execution. Available Sidekiq threads also bound concurrency. Run budgets include reservations; credit, authentication and budget failures pause the run. Leases recover interrupted workers. Failed work remains inspectable after retries are exhausted. Pause stops new work; already active calls can finish.

The local Dokku client supplies this application's name. Start a controlled run and inspect it with:

```sh
dokku run env NAME=initial-discovery TARGET=10000 BUDGET_USD=1 bundle exec rake jev:start
dokku run env RUN_ID=1 bundle exec rake jev:status
dokku run bundle exec rake jev:tick
```

Replace `RUN_ID` with the returned ID. Status includes processing and classification counts, source groups, control bands, reviews, request errors, tokens, estimated spending, reservations, latency and throughput. The authenticated review queue supports run, probability-band, classification, sample-group, review-state, repository and control filters.

For a database-only traversal, set `POPULATION=database`. This includes visible projects across every score band, including already included reference cases, and uses no external repository or package sampling:

```sh
dokku run env NAME=database-check POPULATION=database TARGET=1000 BUDGET_USD=0.10 bundle exec rake jev:start
```

This mode freezes the maximum project ID at creation and advances a persisted primary-key cursor by at most `JEV_BATCH_SIZE` visible rows per scheduler tick. `TARGET` bounds rows examined, including unsupported URLs and normalized duplicate repositories. It is an ordered traversal, not a random sample; an interrupted or budget-paused run resumes its cursor without reseeding. Newly created rows above the ceiling require another run. Visibility is checked during traversal and again during screening. Statistics expose the ceiling, cursor, examined rows, added candidates, unsupported URLs and duplicate URLs. Only supported normalized repository URLs receive candidates; duplicate URLs share one candidate. Deleted and hidden rows are outside the observed visible frame.

To cover a frozen database of fewer than one million rows, use `TARGET=1000000`; traversal ends at the ceiling even if fewer candidates are created. Set the run budget and global budget before starting within the approved spending limit. The enrichment limit still applies, with additional selected candidates recorded as deferred. Screening completes before repository enrichment begins, so a full metadata traversal does not imply full source collection. No automatic catalogue inclusion occurs.

```sh
dokku run env RUN_ID=1 bundle exec rake jev:pause
dokku run env RUN_ID=1 bundle exec rake jev:resume
dokku run env RUN_ID=1 bundle exec rake jev:retry
dokku run env RUN_ID=1 LIMIT=20 bundle exec rake jev:retry_evidence
dokku run env RUN_ID=1 LIMIT=100 bundle exec rake jev:resolve_repositories
dokku run env RUN_ID=1 bundle exec rake jev:reevaluate
```

`retry` resets failed stage attempts. `retry_evidence` clears cached incomplete source collections for a bounded number of completed candidates and queues fresh enrichment. It retains the earlier request ID, source revision and error in collection history; identical resulting model inputs still use the request cache. Checkout errors distinguish unavailable repositories, missing revisions, timeouts, disk/output limits and rate limits, and successful collections record duration in milliseconds. Resume after fixing credentials or increasing the budget within the intended spending limit. `reevaluate` adopts the current model and question fingerprints, invalidates active leases and clears current probabilities and review status. Unchanged successful requests are cached. Old request records and review notes remain stored; detailed review history is not versioned. Use a new named run when preserving an earlier evaluation cohort matters.

`resolve_repositories` adds identity evidence to completed enriched records without rescanning or changing saved model inputs and reviews. It skips checked records by default; `ALL=1` refreshes them. The limit is bounded to 1,000, and the identity filter has a database index. Preserve an earlier evaluation cohort by using a new run to measure collector changes rather than overwriting its evidence.

Completed records are checked incrementally for changed metadata, repository push revision, stored README or Brief statistics and changed question content. The run retains its pinned model until explicit re-evaluation or a new run. Source evidence is recollected when its fingerprint changes. Checks use existing stored project evidence and repository API snapshots, so changes that upstream sources have not indexed remain undetected.

For evaluation, review a seeded sample within each source and screen band, including low controls, deferred enrichment and failures. Report supported discoveries per 100 reviewed, uncertainty and misses separately. Compare both probabilities on the same reviewed repositories. Repeat near-threshold requests with distinct `replicate` values through `Jev::Client#call` to measure stability without replacing the main result. Store those request IDs and the review sampling frame with the report. Do not extrapolate high-probability review precision across the full corpus or expand scans solely because requests are cheap.
