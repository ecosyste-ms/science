# Package discovery and ranking

Science stores direct dependencies as links between `Project` and `Package` records. This supports package browsing, package-derived Science Score evidence, and links from a package back to a project that publishes it. Package identities retain PURLs where possible so records from manifests, Brief, and packages.ecosyste.ms can converge on the same package.

## Data flow

Dependency and package processing runs in bounded scheduled stages. Project sync also stores package records returned for its repository in local `Package` rows and links them to the publishing project.

1. `projects:sync_dependencies` reads stored repos.ecosyste.ms manifests, with Brief as a fallback when the manifest response has no usable direct dependencies. It writes at most 250 projects per run to `project_dependencies`.
2. `packages:sync_registries` imports package registries, PURL types, and default registry settings from packages.ecosyste.ms each day.
3. `packages:resolve_dependencies` groups unresolved rows by PURL or package coordinate. It resolves at most 1,000 identities per scheduled run, creates local `packages` records, and links all matching dependency rows.
4. `packages:sync_metadata` enriches at most 100 dependency-derived packages per run with packages.ecosyste.ms data. Packages used by more direct project dependencies run first.
5. `packages:normalize_rankings` copies ranking values from existing package JSON into dedicated columns in batches of at most 1,000. Each package is processed once unless its upstream metadata changes.
6. `packages:match_projects` checks up to 500 package repository URLs against current project URLs and recorded repository aliases. A valid unmatched URL creates a project and queues its normal sync. A single match sets `published_by_project_id`.
7. `packages:refresh_projects` queues up to 25 publishing projects whose Science Score remains zero and whose last sync is more than seven days old. Projects with more direct scientific dependents run first.

Publishing projects used directly by scientific projects are also eligible for the bounded Brief scan when their current Science Score is zero. Other zero-score projects remain outside the recurring refresh and Brief queues.

The stages run separately so unavailable package metadata does not prevent local dependency indexing. Private or invalid packages may remain without upstream metadata, as may packages from registries missing in packages.ecosyste.ms. Resolution errors and metadata sync errors are recorded to prevent every scheduled run from retrying the same identity.

Explicit registry qualifiers in a PURL take precedence. Otherwise, resolution uses the PURL type's default registry, the imported default for the dependency ecosystem, or the default supplied by the PURL library. Version and subpath components are removed so one `Package` identity covers all releases.

[Project ingestion and sync](project-ingestion-and-sync.md#dependency-indexing) describes source selection, collected empty results, retries, and the manual task options in more detail.

## Explicit Hugging Face imports

`packages:import_huggingface` imports an explicit JSON array of 1 to 500 model PURLs. Sync package registries first with `packages:sync_registries`. For example, `models.json` can contain:

```json
["pkg:huggingface/google-bert/bert-base-uncased"]
```

The task defaults to a dry run, which looks up new packages and prints a JSON report without writes. Set `DRY_RUN=false` to import:

```sh
FILE=models.json bundle exec rake packages:import_huggingface
FILE=models.json DRY_RUN=false bundle exec rake packages:import_huggingface
```

Versions and subpaths are removed, duplicates are combined, and qualifiers are rejected. New models retain the Packages response even when `repository_url` is null. Existing packages are reported without refreshing metadata or changing relationships. Missing Packages records remain retry candidates in the report; no placeholder records are created. Lookup errors and identity conflicts are reported per PURL so successful imports can be reused when the batch is retried.

This task imports package metadata only. Hub files, paper identities and reviewed repository links have separate collection and import steps. The task does not run on a schedule.

Packages can sync versions without a linked publishing project. For an existing package, call `package.sync_versions` to enqueue the normal paginated import from its upstream `versions_url`. This applies to all registries. Packages with a publisher still require that project to be visible and scientific for version imports. Version sync retains its existing retry and refresh intervals.

Hugging Face revisions use the existing `PackageVersion` records: the version number is the commit SHA and the version PURL identifies that revision. A download URL or repository release is not required. The package API advertises `versions_url` for packages without a publisher, and the versions endpoint returns an empty list until versions have been imported. Versions of packages with hidden publishers remain excluded.

To collect intrinsic files for imported versions, put 1 to 25 exact version PURLs in a JSON array and run:

```sh
FILE=model-versions.json bundle exec rake packages:collect_huggingface > model-files.json
```

Each PURL must identify an existing package version with a full commit SHA. The collector checks out that revision without downloading LFS objects and uses Brief to locate README, citation, CodeMeta and Zenodo files. Individual files are limited to 1 MB, must be UTF-8 text, and must resolve inside the checkout.

The JSON report includes package/version IDs, the version PURL, source URLs, retrieval timestamps, content checksums and UTF-8 file contents. Gated, missing and failed files have separate outcomes; successful files remain in the report. Missing revisions do not fall back to the latest revision. Collection makes no database writes, downloads no weights and performs no automatic retries. Rerunning the task fetches the selected versions again, so retain reports outside the application repository when needed for review.

Extract candidates from a collection report, then resolve exact paper identities:

```sh
FILE=model-files.json OUTPUT=model-candidates.json bundle exec rake packages:extract_paper_candidates
FILE=model-candidates.json OUTPUT=model-paper-review.json bundle exec rake papers:resolve_candidates
```

Extraction verifies the package version identity and file checksums before running Brief on the collected files in a temporary directory. Reports are limited to 25 MB and 25 versions. Candidate evidence retains the version PURL, package PURL, file URL, checksum, retrieval time, line range, heading context and source passage. Brief output and parser diagnostics are retained. The Ruby BibTeX parser supplies fields such as `archivePrefix` alongside Brief's parsed entries. Empty citation templates produce no candidates.

DOIs and supported paper identifiers are extracted from citation files and READMEs. Publisher PDF links remain URL candidates instead of deriving a DOI from an arbitrary part of their path. References with only a title or an unsupported identifier stay in the report for review. Configuration files are not treated as citation sources. Neither task creates papers or relationships, and metadata agreement does not assign the model's relationship to the paper.

PubMed references are extracted from `pubmed.ncbi.nlm.nih.gov/<id>` and legacy `ncbi.nlm.nih.gov/pubmed/<id>` links, labelled `PMID:` values, and BibTeX `pmid` fields. Resolution uses an exact OpenAlex PMID lookup and retains any title or author conflicts. The project paper import worker uses the same extraction and resolution for stored READMEs and citation files, including repositories without a README, and saves these links with the `reference` role. CFF extraction reads preferred citations and references, excluding software and dataset entries and the root software DOI. R citation files are scanned for identifiers without executing R.

To collect CRAN citation pages, supply a JSON array of 1 to 25 exact version PURLs for existing `PackageVersion` records:

```sh
FILE=cran-versions.json OUTPUT=cran-files.json bundle exec rake packages:collect_cran
FILE=cran-files.json OUTPUT=cran-candidates.json bundle exec rake packages:extract_paper_candidates
FILE=cran-candidates.json OUTPUT=cran-resolved.json bundle exec rake papers:resolve_candidates
```

The CRAN collector checks the published `DESCRIPTION` before and after fetching `citation.html`. It reports `version_mismatch` for versions other than the current release and rejects a collection if `DESCRIPTION` changes during the requests. Reports retain the original HTML, checksums, source URLs and retrieval timestamps. BibTeX extraction accepts missing citation keys, decodes HTML entities, and records evidence against the original `<pre>` block's line range. Collection and extraction do not write paper relationships; `papers:import_candidates` remains the explicit import step. CRAN collection is not scheduled.

## Package browser and API

`/packages` and `/api/v1/packages` use the same `PackageIndex` query. Both accept `ecosystem`, OpenAlex `domain`, and OpenAlex `field` filters. Domain and field filters limit the dependent project population before package counts are calculated. Each package count is the number of distinct visible scientific projects with a direct dependency on that package.

Packages with a matched publishing project whose Science Score is below 5 are excluded. Packages without a matched project or saved score remain visible while the publishing repository is processed.

The API accepts `page`, `per_page`, and `sort`. For example:

```text
/api/v1/packages?ecosystem=cran&field=medicine&sort=science_relevance
```

Responses include the scientific project count, packages.ecosyste.ms ranking percentages, upstream dependent repository count, relevance inputs, and the package metadata rankings. `science_usage_percentage` compares the scientific project count with the upstream dependent repository count. It remains a diagnostic value because the two services can cover different repository populations and refresh at different times.

When `published_by_project_id` is present, the browser links the package name to the local project. Other packages link to their repository URL when one is available. API responses include both local HTML and API URLs for a matched publishing project.

## Ordering

`scientific_projects` is the default ordering. It sorts by the number of distinct scientific projects that directly depend on each package, then by package name and ID.

`science_relevance` is an experimental ordering that adjusts direct scientific use for general package popularity. packages.ecosyste.ms ranking values are top percentages within a registry, where a smaller value means greater popularity. The score uses the average of the available normalized rankings and caps the adjustment at the top 5 percent:

```text
p = clamp(science_relevance_top_percentage, 0, 5)
popularity_weight = 0.10 + 0.90 * (p / 5)
repository_factor = clamp(repository_science_score, 0, 100) / 100
science_relevance_score = scientific_projects_count * popularity_weight * repository_factor
```

The popularity weight ranges from 0.10 for a package at the top of its registry to 1.0 for a package at or below the top 5 percent. This limits the popularity penalty to tenfold. The repository factor makes Science Score the primary relevance signal. Packages without a matched repository or saved score have no relevance score and sort after scored packages. Direct scientific use remains the base of the score.

Some upstream records report an average top percentage of 100 while their dependent repository rank is 0. The score treats that inconsistent pair as 0. The API returns the raw `average_top_percentage` and the normalized `science_relevance_top_percentage` so this adjustment is visible. A package without ranking metadata has no relevance score and sorts after scored packages. The direct-use ordering continues to include it normally.

The relevance ordering is intended for comparison with the direct-use list. Metadata coverage varies by registry, so it should remain optional until the prioritized metadata sync has covered enough packages and the results have been checked within each registry.

Dependent repository counts and ranking percentages are stored in columns when package metadata is written. The bounded normalization task copies these values for existing rows. Package ordering reads the columns instead of decoding the complete upstream package record for every candidate. Domain and field filters still calculate scientific project counts from their selected project population.

## Dependency kinds

Package counts include direct dependencies only. Each `ProjectDependency` retains its source occurrences, including raw `kind` and `optional` values when supplied by repos.ecosyste.ms or Brief.

Kind values have registry-specific meanings. GitHub Actions use values such as `composite` and `docker` for action implementations. CRAN uses `imports`, `depends`, and `suggests`, while JVM build files use values such as `implementation`, `compile`, and `testImplementation`. The package ranking does not assign global weights to these raw values. A future dependency-role facet should normalize them within each package ecosystem first.

## Signal boundary

Package and dependency evidence can support discovery of scientific software that has no paper, DOI, or formal citation. JOSS and other verified collections provide examples for evaluating these signals, while the target population includes scientific open source software outside those collections.

Paper-mention data is reserved for entity linking, disambiguation, and evaluation after candidates are identified. It is excluded from package ranking and project classification inputs. Once OpenAlex incorporates Science records, some software links may derive from earlier Science classifications. Feeding those links back into the score would create a feedback loop that amplifies prior errors and existing visibility.
