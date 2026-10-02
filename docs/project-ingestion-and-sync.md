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

Selected IDs are sent to `SyncProjectWorker` on the default Sidekiq queue. Each Sidekiq process has nine general threads and one reserved for SWH API jobs. Repository analysis uses `RepositoryScanWorker` on the `swhid` queue, with one checkout for Brief, SWHIDs, and metadata provenance. Duplicate scheduled sync jobs remain possible because selection and queue insertion are separate operations.

## Sync stages

`Project#sync` runs the following stages in order. Individual stages can save their results before the next stage begins:

1. Resolve redirects and validate the repository URL.
2. Fetch repository and owner records, then associate local `Host` and `Owner` rows.
3. Fetch dependency manifests, package records, and package mentions. Package records also create or update local packages and link them to the publishing project.
4. Fetch the README, commits, timeline events, and issue statistics.
5. Import issue rows and repository metadata files.
6. Sync releases, committer records, and contributor-derived keywords.
7. Set `last_synced_at`, update popularity and Science scores, then ping upstream records for refresh.
8. Queue repository analysis or due archive coverage checks for scientific projects with repository metadata. [SWHID scanning](swhids.md) shares its checkout with Brief; API checks use a separate queue.

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

## Wikidata enrichment

Wikidata enrichment links source records to existing visible projects, including projects below the scientific threshold. It does not create projects or change Science Score. Each entity is stored once in `external_software_records`; a separate join table retains its repository relationships and matching evidence. A source can describe several repositories, and each repository can have several identifiers.

The October 2026 sample compared [SymPy](https://www.wikidata.org/wiki/Q5971368), [NumPy](https://www.wikidata.org/wiki/Q197520) and [SciPy](https://www.wikidata.org/wiki/Q197492) against the public project and search-context APIs. All three repository URLs matched existing projects. Names, descriptions and programming languages overlap with repository and package metadata. Wikidata adds QIDs, swMATH identifiers (940, 6294 and 6293 respectively), typed classifications and statement-level provenance that the existing projections do not retain. These three mathematical Python projects do not establish coverage across disciplines.

The NumPy record includes claims sourced from Wikipedia, the Free Software Directory and Open Hub, alongside claims without references. [Wikidata's data access documentation](https://www.wikidata.org/wiki/Wikidata:Data_access) describes the API and query routes. The importer uses the main query graph for repository discovery and the entity API for full records. It retains original statement IDs, ranks, qualifiers and references so later evidence evaluation can distinguish copied claims. Current repository, package and DOI projections do not replace that claim structure; a swMATH identifier alone also does not establish equivalent coverage of the swMATH record. Direct Wikidata enrichment is useful for these additions. Other registries need their own overlap checks before adding refresh jobs.

`wikidata:sweep` starts a background import or resumes its saved progress. Each job reads at most 100 repository-linked items, retrieves entities in batches of at most 50, and queues the next page after 15 seconds. The import stores its unfinished page and advances its cursor only after all those records have an `ok` or `missing` source status. Successful batches within a failed page use cached records on retry. Query failures retry after an hour; rate limits and replication lag use the shared cooldown. The cursor follows lexicographic QID order.

Only one sweep per source can run at a time. A ten-minute database lease prevents overlapping jobs, and an expired worker cannot update the replacement worker's progress. `wikidata:resume` runs every ten minutes to recover unfinished imports after interruptions, including failure to enqueue the next page. It does nothing before a sweep is started or after completion. Network requests happen outside the short transactions used to claim work and save progress.

Use `AFTER` to start from a cursor returned by a manual import, and `LIMIT` to choose a page size between 1 and 100. Omit both when resuming an existing sweep. `wikidata:status` reports the cursor, completed page and item counts, unfinished items, retry time and last error. A completed sweep stays complete until `RESTART=true` explicitly starts another pass. Start that pass without `AFTER` to pick up newly linked older items.

```bash
bundle exec rake wikidata:sweep
bundle exec rake wikidata:status
RESTART=true bundle exec rake wikidata:sweep
```

With the local Dokku client, use `dokku run bundle exec rake wikidata:sweep` and `dokku run bundle exec rake wikidata:status`. The client supplies the app name from the repository's Dokku remote. A first sweep that continues a manual import can use `dokku run env AFTER=Q102310494 bundle exec rake wikidata:sweep`.

`wikidata:import` remains available for one manual page or explicit IDs. Both import paths use `external_metadata`. The queue capsule runs one job per worker process; each process keeps ten threads: eight for the default queues, one for Software Heritage API work and one for external metadata. The query uses all `P1324` statement ranks; matching accepts normal and preferred statements, while deprecated statements remain only in the stored source record. Publication queries are outside this import and would need to account for Wikidata's separate scholarly graph.

```bash
LIMIT=100 bundle exec rake wikidata:import
AFTER=Q5971368 LIMIT=100 bundle exec rake wikidata:import
IDS=Q5971368,Q197520,Q197492 bundle exec rake wikidata:import
LIMIT=100 bundle exec rake wikidata:refresh
```

Run `wikidata:refresh` periodically to queue due records, with a maximum of 1000 per invocation. Successful records are cached for 30 days, missing records for seven days, and failures for one hour. Re-enqueuing a cached ID does not fetch it again. Rate limits and replication lag share a cooldown across workers and reschedule after `Retry-After`; other source failures have three hourly job retries. Missing records and transient failures retain the last successful record and links with an explicit source status. A successful response replaces withdrawn relationships. Unmatched source records remain cached and are matched again on their next refresh.

Matching checks existing case-insensitive URL and alias indexes in batches of at most 100 URLs, selecting only project identity fields. Shared aliases retain every candidate as ambiguous. Distinct repository statements within a suite can each produce a match. Refresh selection uses the `(source, next_refresh_at, id)` index, and project reads use the join table's project index. Network requests occur before row locks; unchanged evidence does not rewrite joins or project metadata.

`GET /api/v1/projects/:id/external_identifiers` returns cached identifiers, relationship evidence, source status, timestamps and entity metadata. Pagination accepts `page` and `per_page` (maximum 100). An empty list does not prove that a project lacks external identifiers. Hidden projects return 404. The endpoint performs no upstream requests or background work.

`homepage:refresh` also caches the external-source breakdown with the existing homepage statistics. Each source counts distinct visible scientific projects with unambiguous matches. Several identifiers from the same source count once; a project can count under several sources. Missing records are excluded, while previously retrieved evidence survives a failed refresh. Homepage requests only read the cache, including when the cache is empty. Run `bundle exec rake homepage:refresh` after an import to update the displayed counts.

## bio.tools enrichment and registry references

bio.tools imports use the same source-record and repository-link tables as Wikidata. IDs are stored in lowercase because bio.tools IDs are case-insensitive. Repeated imports update one `(source, identifier)` record, and several links to the same project share one relationship. Matching uses explicit `link` entries typed `Repository`, including known repository aliases. Homepages, documentation, downloads and related-tool names do not establish identity. Missing repository links remain unmatched; the importer does not create projects.

The October 2026 audit checked eight bio.tools records, their available Wikidata counterparts, and Science's public project metadata. Scanpy and MultiQC add EDAM operations and topics; several publication DOIs and Nextflow contributor ORCIDs were already present in Science. [RSEc](https://research-software-ecosystem.org/docs) preserved the compared repository links, annotations, credits and publication identifiers in all eight sample copies. Two of the 50 newest bio.tools records were absent from the checked RSEc snapshot. Direct bio.tools retrieval therefore supplies current metadata and familiar registry references, while further feeds can supply additional coverage. A mirrored bio.tools record should retain its original source identity; another collection route is not independent scientific evidence. This importer reads the bio.tools API. Scoring is unchanged.

`biotools:sweep` starts or resumes a persisted catalogue import. It reads up to 50 full records per request, ordered by addition date, and stores the unfinished page before matching. Continuations wait 15 seconds. A retry reuses the saved page and skips records already retrieved at that time or later. The worker uses the existing ten-minute lease and checks its token before changing progress. Page requests happen outside database transactions; matching uses batches of at most 100 indexed repository URLs. A project-page request selects registry names and identifiers without loading the source metadata.

```bash
bundle exec rake biotools:sweep
bundle exec rake biotools:status
IDS=scanpy,multiqc,nextflow bundle exec rake biotools:import
LIMIT=100 bundle exec rake biotools:refresh
RESTART=true bundle exec rake biotools:sweep
```

`LIMIT` on `biotools:sweep` sets a page size between 1 and 50; omit it when resuming. A completed sweep requires `RESTART=true` to begin another catalogue pass. Page-number pagination can shift when upstream records are removed, so later passes are needed to revisit the catalogue. `biotools:resume biotools:refresh` runs every ten minutes, recovering due unfinished sweeps and queuing up to 100 due source records. Recovery does not start a sweep or restart a completed one. Individual records have the same 30-day success, seven-day missing and one-hour failure intervals as Wikidata; rate limits share a separate bio.tools cooldown and honor `Retry-After`.

Project pages display an **Elsewhere** section linking confirmed Wikidata, bio.tools, ASCL and swMATH identifiers, including projects whose repository sync has not finished. Ambiguous and missing records are omitted; an unsuccessful refresh retains the last confirmed reference. The paginated external-identifiers API exposes the full cached source record, match evidence and canonical `record_url`. Neither display path fetches source data or changes scores. The cached homepage source breakdown labels this source `bio.tools` and counts each scientific project once for it.

## ASCL enrichment

ASCL imports read the [JSON catalogue](https://ascl.net/code/json) and compare its published IDs with the [search API](https://ascl.net/api/search/?q=%22%22&fl=ascl_id) before storing records. The October 2026 audit found 4,105 published records in a 4.6 MB catalogue; the index also contained unassigned `0000.000` rows, which are excluded. A missing, malformed or incomplete response preserves previously stored records. The validated catalogue is cached for six hours in chunks of at most 256 KB, below Memcached's item limit. The cache index is published after all chunks are written; an evicted chunk causes a validated refetch. Matching processes at most 50 records per page with indexed repository and alias lookups.

The eight-record sample included MESA, yt, REBOUND, emcee, Astropy, Photutils, corner.py and GADGET-4. Four explicit repository URLs matched existing Science projects; GADGET-4 had an explicit repository without a match. The other three records supplied only homepages or documentation. ASCL adds its own identifiers, credits, descriptions, preferred citations and separate lists of papers using or describing software. The checked RSEc Astropy record contained only container metadata, while the checked Wikidata Astropy record supplied a repository URL but no ASCL identifier. These sample checks support retaining ASCL records directly; they do not establish catalogue-wide overlap.

Matching accepts repository URLs from `site_list`, including GitHub Pages project URLs, and retains the original source fields. Generic homepages, documentation domains and paper links remain in the cached metadata without creating repository relationships. ASCL references appear in **Elsewhere**, the external-identifiers API and cached homepage source counts. Source records do not change Science Score; new repository candidates use the separate discovery task below.

```bash
IDS=1609.011,1010.083,1110.016 bundle exec rake ascl:import
bundle exec rake ascl:sweep
bundle exec rake ascl:status
LIMIT=100 bundle exec rake ascl:refresh
RESTART=true bundle exec rake ascl:sweep
```

`ascl:sweep` stores each unfinished page before matching and continues after 15 seconds. `LIMIT` sets a page size between 1 and 50; omit it when resuming. Records are ordered by identifier. A completed sweep requires `RESTART=true` for another catalogue pass, including records added before the saved cursor. The scheduled `ascl:resume ascl:refresh` runs every ten minutes, recovering unfinished sweeps and queuing up to 100 due records. It does not start or restart a sweep. Successful records refresh after 30 days, missing records after seven days, and failed requests after an hour. Rate limits share an ASCL cooldown and honor `Retry-After`.

Wikidata, bio.tools, ASCL and bulk repository lookup share GitHub Pages conversion. A project URL such as `https://dhubber.github.io/seren/seren.html` maps to `https://github.com/dhubber/seren`; nested documentation paths are discarded. Source evidence preserves the original URL and records `url_transformation: github_pages`. Direct links, converted links and known aliases resolve through the same lookup, so they can share one project relationship. Root Pages sites, custom domains and top-level HTML or PDF files are not converted.

## swMATH enrichment through zbMATH Open

The [zbMATH Open API](https://api.zbmath.org/) supplies swMATH software records without an API key. The October 2026 audit found 43,408 records through its cursor-based `v1/software/_all` endpoint, also used by the [MaRDI harvester](https://github.com/MaRDI4NFDI/python-zbMathRest2Oai). The sampled first 100 records had three explicit source-code links; another 50 records after ID 1000 had two, and ten records after ID 40000 had four. Adding the named sample produced 13 distinct repository candidates, nine without a match in Science. These small samples do not estimate overall coverage.

Wikidata already supplied swMATH IDs for SymPy, NumPy and SciPy. Direct records add mathematical classifications, software relationships and publication metadata. The checked RSEc NumPy and SymPy bio.tools copies did not contain swMATH or zbMATH fields. MaRDI's exporter copies swMATH IDs, repository URLs, classifications and standard articles, but its inspected metadata export omits several raw fields, including software licence terms. Direct retrieval supports both repository discovery and identifier enrichment while retaining the collection route. Copied metadata is not independent scoring evidence.

Only the explicit `source_code` field supplies repository candidates. Homepage URLs, related-software names and shared names do not establish identity. In the audit, SciPy had no source-code URL, FEniCS pointed to an organisation, and SymPy pointed to its website repository. Those fields are preserved as supplied; the importer does not replace them with guessed implementation repositories. Known repository aliases and GitHub Pages conversion use the shared matching path. Classification and article counts do not affect Science Score, and an article-count-only change does not request another project sync.

```bash
IDS=6294,825,14241 bundle exec rake swmath:import
bundle exec rake swmath:sweep
bundle exec rake swmath:status
LIMIT=100 bundle exec rake swmath:refresh
RESTART=true bundle exec rake swmath:sweep
```

Sweeps request up to 50 full records, validate ascending IDs and the returned cursor, and save each page before matching. Continuations wait 15 seconds. Retries reuse saved records; incomplete pages and unexpected missing responses leave progress unchanged. The scheduled `swmath:resume swmath:refresh` runs every ten minutes, recovering unfinished sweeps and queuing up to 100 due records. Completed sweeps require an explicit restart. Refresh intervals are 30 days after success, seven days for a confirmed missing record, and an hour after failure, with a shared cooldown for rate limits.

Project pages link to the record on zbMATH Open, and the API retains source metadata, repository evidence, the collection URL and `CC-BY-SA-4.0` attribution. The API withholds some descriptions and publication text because of conflicting licences; its placeholder text remains in the raw record. swMATH uses the existing source-record indexes and cached homepage counts, with no source requests during page rendering.

## Repository discovery from cached sources

`external_software:discover` queues a separate worker that reads up to 100 due Wikidata, bio.tools, ASCL or swMATH records. It uses the stored repository statements, normalized URLs and indexed aliases to attach evidence to existing projects or create minimal projects. GitHub and GitLab hosts already recorded in `hosts` are supported for creation, with `gitlab.com` included by default. Nested GitLab namespaces are preserved. Other hosts remain in the discovery results as unsupported candidates. Hidden owners are excluded, and ambiguous matches retain all candidate projects without requesting enrichment.

Run `bundle exec rake external_software:discover` to start a batch, or set `LIMIT=10` for a smaller batch. The task runs every ten minutes and also recovers pending project sync requests. `bundle exec rake external_software:discovery_status` reports due records by source, failed records and pending syncs. Each source record stores its latest candidate outcomes and the IDs it created in `discovery_result`; worker logs count created, existing, ambiguous, hidden and unsupported repository URLs by source. These are per-source counts, so overlapping sources can report the same project.

New projects enter the normal `SyncProjectWorker` path through a durable request keyed by project ID. New source evidence also requests enrichment for unsynced and zero-score projects. Unchanged metadata, reordered fields and source update timestamps do not request another sync. A sync request remains pending until the worker completes, with a one-hour lease and retry delay after failure. Requests arriving during a sync remain pending for a later run. Queue failures leave the database requests available for recovery.

Discovery performs no source HTTP requests and awards no Science Score points. Normal enrichment calculates the score from repository and publication evidence. Changed source records become due again; unresolved candidates are revisited after 30 days. Discovery selects through a partial due-record index and uses bounded URL and alias queries, without scanning project metadata. Each source record and its project links commit together; a failed record retries after an hour while later records can proceed.

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
