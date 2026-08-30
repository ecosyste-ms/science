# Project ingestion and sync

Project ingestion creates or updates repository URLs from known research-software sources. Project sync then enriches those records through ecosyste.ms APIs and repository files. Most importers save a minimal `Project` and enqueue `SyncProjectWorker`; the importer completing successfully does not mean that repository metadata and Science Score are already present.

## Scheduled discovery

The regular discovery tasks are defined in `app.json`. Import and sync run as separate scheduled entries:

| Schedule | Task | Source |
| --- | --- | --- |
| Every 30 minutes | `projects:import_joss` | Published JOSS papers |
| Daily at 00:00 | `projects:import` | JOSS, papers.ecosyste.ms, CRAN, Bioconductor, conda-forge, and reviewed Open Sustainable Technology projects |
| Daily at 01:00 | `projects:import_metadata_repositories` | Repository links in citation and metadata files |
| Every 10 minutes | `projects:sync` | Projects due for metadata refresh |

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
