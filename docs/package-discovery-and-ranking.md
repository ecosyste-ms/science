# Package discovery and ranking

Science stores direct dependencies as links between `Project` and `Package` records. This supports package browsing, package-derived Science Score evidence, and links from a package back to a project that publishes it. Package identities retain PURLs where possible so records from manifests, Brief, and packages.ecosyste.ms can converge on the same package.

## Data flow

Dependency and package processing runs in bounded scheduled stages:

1. `projects:sync_dependencies` reads stored repos.ecosyste.ms manifests, with Brief as a fallback when the manifest response has no usable direct dependencies. It writes at most 250 projects per run to `project_dependencies`.
2. `packages:sync_registries` imports package registries, PURL types, and default registry settings from packages.ecosyste.ms each day.
3. `packages:resolve_dependencies` groups unresolved rows by PURL or package coordinate. It resolves at most 1,000 identities per scheduled run, creates local `packages` records, and links all matching dependency rows.
4. `packages:sync_metadata` enriches at most 100 packages per run with packages.ecosyste.ms data. Packages used by more direct project dependencies run first.
5. `packages:normalize_rankings` copies ranking values from existing package JSON into dedicated columns in batches of at most 1,000. Each package is processed once unless its upstream metadata changes.
6. `packages:match_projects` checks up to 500 package repository URLs against current project URLs and recorded repository aliases. A single match sets `published_by_project_id`.

The stages run separately so unavailable package metadata does not prevent local dependency indexing. Private or invalid packages may remain without upstream metadata, as may packages from registries missing in packages.ecosyste.ms. Resolution errors and metadata sync errors are recorded to prevent every scheduled run from retrying the same identity.

Explicit registry qualifiers in a PURL take precedence. Otherwise, resolution uses the PURL type's default registry, the imported default for the dependency ecosystem, or the default supplied by the PURL library. Version and subpath components are removed so one `Package` identity covers all releases.

[Project ingestion and sync](project-ingestion-and-sync.md#dependency-indexing) describes source selection, collected empty results, retries, and the manual task options in more detail.

## Package browser and API

`/packages` and `/api/v1/packages` use the same `PackageIndex` query. Both accept `ecosystem`, OpenAlex `domain`, and OpenAlex `field` filters. Domain and field filters limit the dependent project population before package counts are calculated. Each package count is the number of distinct visible scientific projects with a direct dependency on that package.

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
repository_boost = 1 + clamp(repository_science_score, 0, 100) / 100
science_relevance_score = scientific_projects_count * popularity_weight * repository_boost
```

The popularity weight ranges from 0.10 for a package at the top of its registry to 1.0 for a package at or below the top 5 percent. This limits the popularity penalty to tenfold. A matched repository Science Score adds a positive boost from 1x to 2x. Packages without a matched repository or saved score receive a 1x boost, since package matching and project scoring coverage remain incomplete. Direct scientific use remains the base of the score.

Some upstream records report an average top percentage of 100 while their dependent repository rank is 0. The score treats that inconsistent pair as 0. The API returns the raw `average_top_percentage` and the normalized `science_relevance_top_percentage` so this adjustment is visible. A package without ranking metadata has no relevance score and sorts after scored packages. The direct-use ordering continues to include it normally.

The relevance ordering is intended for comparison with the direct-use list. Metadata coverage varies by registry, so it should remain optional until the prioritized metadata sync has covered enough packages and the results have been checked within each registry.

Dependent repository counts and ranking percentages are stored in columns when package metadata is written. The bounded normalization task copies these values for existing rows. Package ordering reads the columns instead of decoding the complete upstream package record for every candidate. Domain and field filters still calculate scientific project counts from their selected project population.

## Dependency kinds

Package counts include direct dependencies only. Each `ProjectDependency` retains its source occurrences, including raw `kind` and `optional` values when supplied by repos.ecosyste.ms or Brief.

Kind values have registry-specific meanings. GitHub Actions use values such as `composite` and `docker` for action implementations. CRAN uses `imports`, `depends`, and `suggests`, while JVM build files use values such as `implementation`, `compile`, and `testImplementation`. The package ranking does not assign global weights to these raw values. A future dependency-role facet should normalize them within each package ecosystem first.

## Signal boundary

Package and dependency evidence can support discovery of scientific software that has no paper, DOI, or formal citation. JOSS and other verified collections provide examples for evaluating these signals, while the target population includes scientific open source software outside those collections.

Paper-mention data is reserved for entity linking, disambiguation, and evaluation after candidates are identified. It is excluded from package ranking and project classification inputs. Once OpenAlex incorporates Science records, some software links may derive from earlier Science classifications. Feeding those links back into the score would create a feedback loop that amplifies prior errors and existing visibility.
