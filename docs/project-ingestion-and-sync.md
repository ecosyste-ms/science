# Project ingestion and sync

Project ingestion creates or updates repository URLs from known research-software sources. Project sync then enriches those records through ecosyste.ms APIs and repository files. Most importers save a minimal `Project` and enqueue `SyncProjectWorker`; the importer completing successfully does not mean that repository metadata and Science Score are already present.

## Scheduled discovery

The regular discovery tasks are defined in `app.json`. Import and sync run as separate scheduled entries:

| Schedule | Task | Source |
| --- | --- | --- |
| Every 30 minutes | `projects:import_joss` | Published JOSS papers |
| Daily at 00:00 | `projects:import` | JOSS, papers.ecosyste.ms, CRAN, Bioconductor, conda-forge, and reviewed Open Sustainable Technology projects |
| Daily at 01:00 | `projects:import_metadata_repositories` | Repository links in citation and metadata files |
| Daily at 02:00 | `packages:sync_registries` | Package registries and their default status from packages.ecosyste.ms |
| Every 10 minutes | `projects:sync` | Projects due for metadata refresh |
| Every 10 minutes | `projects:fetch_brief` | Eligible repositories missing Brief dependency data |
| Every 10 minutes, offset by 3 minutes | `projects:sync_dependencies` | Stored direct dependencies awaiting indexing |
| Every 10 minutes, offset by 4 minutes | `packages:normalize_rankings` | Package ranking metadata awaiting normalized columns |
| Every 10 minutes, offset by 6 minutes | `packages:resolve_dependencies` | Unresolved dependency identities awaiting local package records |
| Every 10 minutes, offset by 7 minutes | `projects:sync_repository_aliases` | Previous repository names awaiting indexed aliases |
| Every 10 minutes, offset by 8 minutes | `packages:sync_metadata` | Local packages awaiting packages.ecosyste.ms metadata |
| Every 10 minutes, offset by 9 minutes | `packages:match_projects` | Package repository URLs awaiting project links |

The JOSS importer stores the paper JSON in `joss_metadata`. Existing projects receive updated JOSS metadata, while new projects are queued for sync. The papers and registry importers currently accept GitHub repository URLs. The reviewed OST importer also limits its imports to GitHub.

Manual tasks can discover repositories through GitHub topics, package keywords, or all repositories belonging to a selected GitHub owner. The broad `projects:discover` task chooses terms from the application's relevant-keyword list, while `import_all_joss_topics` and `import_all_joss_keywords` derive discovery terms from existing JOSS projects.

```bash
bundle exec rake 'projects:import_github_topic[astronomy]'
bundle exec rake 'projects:import_package_keyword[genomics]'
bundle exec rake 'projects:import_github_owner[underworldcode]'
bundle exec rake projects:discover
```

Repository links extracted from CITATION, CodeMeta, and Zenodo data follow a separate normalization and duplicate-checking path described in [Citation metadata and repository discovery](citation-metadata-and-discovery.md). That importer runs daily after the broad source imports.

## Sync selection and queueing

`projects:sync` calls `Project.sync_least_recently_synced`. Each run selects at most 500 projects whose `last_synced_at` is missing or older than one day. The recurring scope includes projects that have never received a Science Score, plus projects whose saved score is positive. A previously synced project with score zero drops out of this recurring refresh scope.

Selected IDs are sent to `SyncProjectWorker` on the default Sidekiq queue. Sidekiq runs with concurrency 10; the default queue has weight 5 and the clone-heavy Brief queue has weight 1. Duplicate scheduled sync jobs remain possible because selection and queue insertion are separate operations.

## Sync stages

`Project#sync` runs the following stages in order. Individual stages can save their results before the next stage begins:

1. Resolve redirects and validate the repository URL.
2. Fetch repository and owner records, then associate local `Host` and `Owner` rows.
3. Fetch dependency manifests, package records, and package mentions.
4. Fetch the README, commits, timeline events, and issue statistics.
5. Import issue rows and repository metadata files.
6. Sync releases, committer records, and contributor-derived keywords.
7. Set `last_synced_at`, update popularity and Science scores, then ping upstream records for refresh.

The repository lookup supplies host data, archive URLs, metadata filenames, release endpoints, and manifest endpoints. Other stages call packages.ecosyste.ms, commits.ecosyste.ms, issues.ecosyste.ms, timeline.ecosyste.ms, and archives.ecosyste.ms. Project keywords combine repository topics with package keywords case-insensitively.

README and CodeMeta files normally come through archives.ecosyste.ms using the repository archive and detected path. Each has a raw repository fallback. CITATION and Zenodo files use the archive path reported by repository metadata.

## Dependency indexing

Repository sync stores the repos.ecosyste.ms manifest response in `projects.dependencies`. Brief scans store their direct and transitive dependency results in `projects.brief`. The scheduled `projects:sync_dependencies` task processes at most 250 projects per run and accepts `LIMIT` values up to 1000.

The indexer records direct dependencies in `project_dependencies`. Repos manifest data has priority when it contains usable direct dependencies. Brief is the fallback when the repos response is empty or has no usable direct dependencies. Each row keeps its source and manifest occurrences in `metadata`.

A missing repos response and a Brief result without a `dependencies` key mean that dependency collection has not happened yet, so the project is not marked as indexed. An empty array is a collected result with no dependencies and is marked once. A later change to either stored source clears `dependencies_indexed_at` and makes the project eligible again. Invalid payloads set `dependencies_index_error`; pass `RETRY_ERRORS=true` for an explicit retry.

```bash
LIMIT=250 bundle exec rake projects:sync_dependencies
RETRY_ERRORS=true LIMIT=25 bundle exec rake projects:sync_dependencies
```

`packages:resolve_dependencies` groups unresolved rows by PURL or package coordinate and processes at most 1000 identities per run. It selects explicit registries from PURL qualifiers, then uses the PURL or ecosystem default. Namespaces follow packages.ecosyste.ms naming: Maven uses `:`, while npm, Go, and other namespaced package types use `/`.

Resolution creates local `packages` rows and links every matching `project_dependencies` row. It does not require the package to be publicly available, so a valid internal package can retain its identity before external metadata is found. A malformed coordinate or unknown explicit registry records `package_resolution_attempted_at` and `package_resolution_error` once. Docker coordinates beginning with a registry hostname remain unresolved unless that registry exists in `package_registries`.

```bash
LIMIT=1000 bundle exec rake packages:resolve_dependencies
RETRY_ERRORS=true LIMIT=100 bundle exec rake packages:resolve_dependencies
```

`projects:sync_repository_aliases` processes at most 500 projects per run. It normalizes the previous repository names stored by repos.ecosyste.ms and writes indexed `project_repository_aliases` rows. A change to the stored repository record makes the project eligible again. Errors are recorded once unless `RETRY_ERRORS=true` is passed.

`packages:sync_metadata` looks up at most 100 local packages per run. It uses the canonical PURL when present and a registry-scoped name lookup otherwise. A match stores the packages.ecosyste.ms ID, canonical PURL, namespace, repository URL, upstream update time, and complete API record. Matched packages refresh after 30 days.

Package metadata writes dependent repository counts and normalized ranking percentages to dedicated columns. `packages:normalize_rankings` copies these values from existing package JSON in batches of at most 1000. A completion timestamp keeps processed rows out of later batches, including packages whose upstream record has no ranking values.

A missing lookup is retried after one day and then seven days. The third miss is marked `unavailable` and left for manual retry because the identity may be private, invalid, or absent from the upstream index. API failures retry after one hour, six hours, and one day before stopping. Ambiguous lookups also require a manual retry. Pass `RETRY_STOPPED=true` to include unavailable, failed, and ambiguous packages.

`packages:match_projects` processes at most 500 packages per run. It normalizes HTTPS, Git, and SSH repository URLs, then checks current project URLs and indexed previous names. A single match sets `published_by_project_id`. A valid unmatched repository creates a project and queues its normal sync. Invalid and ambiguous repository matches store `repository_match_error` and become eligible again after 30 days.

```bash
LIMIT=500 bundle exec rake projects:sync_repository_aliases
RETRY_ERRORS=true LIMIT=50 bundle exec rake projects:sync_repository_aliases
LIMIT=100 bundle exec rake packages:sync_metadata
RETRY_STOPPED=true LIMIT=25 bundle exec rake packages:sync_metadata
LIMIT=1000 bundle exec rake packages:normalize_rankings
LIMIT=500 bundle exec rake packages:match_projects
```

## Partial results and hidden owners

The complete sync is not wrapped in one database transaction. Most fetch stages handle an upstream failure locally and allow later stages to continue, so a project can hold fresh package data and older issue or commit data after the same run. Slow stages of at least five seconds are included in a structured timing log; a total sync of at least 30 seconds records every stage duration.

Sync stops before enrichment when the project belongs to a hidden owner. Owner data returned as hidden also creates or updates a hidden local owner, after which later syncs stop. Redirects that collide with another saved URL can remove the duplicate project during URL checking.

The final upstream pings request refreshes for repository, issue, commit, package, and owner records. They do not block the local values already saved during the run.

## Running and inspecting sync

The scheduled task only enqueues work. Sidekiq performs the selected project syncs:

```bash
bundle exec rake projects:sync
```

Run one project synchronously in a Rails console when debugging a specific record. This makes the upstream requests inside the console process:

```ruby
project = Project.find(476); project.sync; project.reload; puts "last_synced_at: #{project.last_synced_at.inspect}"; puts "science_score: #{project.science_score.inspect}"; nil
```

Queue the production path for one project with the following block. The console returns after inserting the Sidekiq job:

```ruby
project = Project.find(476); project.sync_async; puts "queued_project_id: #{project.id.inspect}"; nil
```

Inspect the population used by the recurring task without materializing project records. This query uses the same eligibility and age conditions as the task:

```ruby
due = Project.should_sync.where(last_synced_at: nil).or(Project.should_sync.where("last_synced_at < ?", 1.day.ago)); puts "projects_due: #{due.count.inspect}"; puts "never_synced: #{due.where(last_synced_at: nil).count.inspect}"; nil
```
