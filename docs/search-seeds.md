# Software search seeds

`GET /api/v1/projects/search_seeds` returns names and identifiers for finding software candidates in paper text. Each seed retains its source and its connection to a Science project or registry package, so a detector can resolve a hit back to software metadata. Those identities also provide a basis for later integrations with OpenAlex's paper–software mention data.

The endpoint reads stored metadata without making upstream requests. It includes visible projects with a Science Score of at least 20, including archived projects and projects without registry packages. Dependencies and incidental README references are excluded from the seed set. Science Score describes the project's scientific relevance; it does not measure confidence in a text match.

## Requests and pagination

Request the first page with:

```http
GET /api/v1/projects/search_seeds?per_page=100&page=1
```

`page` starts at 1. `per_page` defaults to 100 and is capped at 100 projects, regardless of how many seeds or packages each project has. Results are ordered by ascending project ID.

Follow the response's `Link` header entry with `rel="next"` until no next link remains. `Current-Page` and `Page-Items` report the page number and configured page size. There are no total-count or total-pages headers. An empty or out-of-range page returns an empty JSON array.

This endpoint returns a live view of the catalogue. Projects can enter or leave the eligible population between requests, which can shift page boundaries. For repeatable experiments, save the responses and retrieval date locally, deduplicate by project ID, and reuse that saved input. Pagination does not provide a consistent database snapshot or a dataset version.

## Response fields

The response is an array with one object per project:

| Field | Meaning |
| --- | --- |
| `project_id` | Local Science project ID |
| `repository_url` | Project repository URL |
| `science_score` | Saved scientific relevance score |
| `updated_at` | Project record update time |
| `last_synced_at` | Project sync time, or `null` |
| `search_year` | Release evidence and a nullable suggested start year for this project |
| `seeds` | Seeds associated with the project |
| `packages` | Package identities and their own seeds; may be empty |

The project timestamps are not freshness guarantees for every seed. Package metadata and repository alias records can be updated separately.

A name seed has this shape:

```json
{
  "type": "name",
  "value": "OrbDot",
  "normalized_value": "orbdot",
  "source": "project.name",
  "relation": "software",
  "name_evidence": {
    "kind": "unknown",
    "source": "project.name",
    "value": "OrbDot"
  }
}
```

`type` is one of `name`, `repository_url`, `homepage_url`, `doi`, `rrid`, `wikidata`, `biotools`, `ascl`, or `swmath`. `value` retains the trimmed source spelling; DOI values contain the extracted identifier. `normalized_value` is intended for matching:

- Names use Unicode NFC and lowercase, preserving punctuation. There is no stemming or word-boundary policy.
- DOIs are lowercase.
- URLs have lowercase schemes and hosts, with path case preserved. Repository history may already have been normalized before storage.
- RRIDs use uppercase `SCR_` identifiers without an optional `RRID:` prefix. Wikidata IDs use uppercase, bio.tools IDs use lowercase, and ASCL and swMATH IDs retain registry spelling.

`source` identifies the metadata field, such as `codemeta.alternateName` or `citation_cff.preferred-citation.doi`. The same value can occur several times with different sources. Preserve those evidence records even if the matcher searches the string only once.

Name seeds also contain `name_evidence`, with the original value, source and origin kind. Direct metadata names use `declared_metadata`; repository URL names use `repository_slug`; package names use `package_name`. Automatic display-name refreshes record their chosen source, including `derived_heading` for a model README heading and `repository_name` for repository metadata. Older automatic names without a recorded source use `derived_unknown`, while other historical display names use `unknown`. Equal text alone does not establish where a stored display name came from. Changing a display name away from its recorded automatic value prevents the old origin from being attached to it.

Each package contains `package_id`, `purl`, `registry`, `ecosystem`, `search_year`, and `seeds`. Linked local package records have a `package_id`; unmatched package metadata stored on the project has `package_id: null`. PURLs omit version and subpath, and may also be `null` when missing or invalid. Registry and ecosystem fields can be missing on older metadata.

Package metadata with the same normalized PURL is combined within the project, retaining seeds from both sources. For example, `package.name` and `project.packages[0].name` can appear under one package. Without a matching PURL, entries remain separate. The array position in a source path refers to the stored metadata at extraction time and should not be used as a permanent identifier.

## Sources and relationships

Project seeds come from the project name and repository URL, repository homepage and rename history, and selected citation metadata. CFF contributes the root title, URL, code repository, DOI identifiers, and preferred-citation DOIs. CodeMeta contributes names, alternate names, homepage, code repository, identifiers, and reference-publication DOIs. Zenodo contributes its root DOI and documentation DOIs, while JOSS contributes its publication DOI. BibTeX citation content supplies DOI fields and DOI resolver URLs.

Package seeds contain names and homepages from linked package records and package metadata stored on the project. Arbitrary links in citation references, CodeMeta related links, and Zenodo references are not promoted to software aliases. Invalid optional metadata is skipped so usable seeds can still be returned.

Confirmed links to RRID, Wikidata, bio.tools, ASCL, swMATH and software DOI records contribute identifier seeds. Links must have `match_status: matched`, retrieved evidence, and a software or source-code relationship. Registry records with status `ok` are included, as are records with status `error` that retain previously retrieved evidence. Missing records, ambiguous matches and publication relationships are excluded. A suite identifier can remain linked to several projects.

These seeds add `identifier_evidence`, with the scheme, registry record ID, project link ID, record URL, relationship, retrieval time, source status and stored matching evidence. The `source` is `external_software_records.identifier`; the nested evidence identifies the particular record and preserves duplicate provenance. Publication DOIs from citation metadata retain their existing relations.

The `relation` field preserves distinctions needed when evaluating a hit:

| Relation | Meaning |
| --- | --- |
| `software` | A name, location, or identifier associated with the software record |
| `publication` | A publication DOI from JOSS, CodeMeta reference publications, or Zenodo documentation links |
| `preferred_citation` | A DOI from a CFF preferred citation, whose target may be software or a publication |
| `citation` | A DOI from BibTeX citation content, without an inferred target type |
| `reference` | A root DOI identifier from a CFF record typed as a dataset |

These relationships describe source metadata. A publication DOI hit can identify a citation target, but it does not establish that the paper used the software. Repository and package metadata can also contain incorrect associations; provenance makes those claims inspectable.

## Search years

Each project and package has its own `search_year` object. For example:

```json
{
  "earliest_release_at": "2012-05-01T00:00:00Z",
  "suggested_start_year": 2011,
  "evidence": [
    {"source": "package.first_release_published_at", "date": "2012-05-01T00:00:00Z", "supports_bound": true}
  ]
}
```

An explicit package `first_release_published_at` supports a bound. Collected package versions support one after a completed initial scan for the current package identity, with no conflicts or undated versions. Project release history requires every configured tag and release source to have completed a scan for its current URL, without conflicts, an active or incomplete scan, errors, or undated records. Draft forge releases are excluded. Evidence includes the source field, source URL and scan completion time where available, plus total and dated record counts for collected histories.

The suggested year is one year before the earliest retained date, to allow for preprints. An observed date can remain in `earliest_release_at` while `suggested_start_year` is null because the history is incomplete. Missing evidence also produces a null bound. Repository creation and record update dates are not release dates. Project dates do not become package dates, and a package date does not set its project's bound.

The year is a search optimization based on the stored evidence. Upstream histories can omit older releases. Consumers should keep the evidence inspectable and allow searches outside the suggested bound.

## Using seeds in a detector

Build a lookup from each normalized seed to all candidate project and package identities. Names can collide across unrelated projects and registries, and forks can retain the same name. Keep the complete repository URL and owning identity when resolving those cases. A package-level seed can support a package candidate; a project-level seed alone cannot select a registry package or release.

Treat seed strings as literal search input and escape them if the matcher uses regular expressions. Preserve surrounding text and the matched seed's provenance for later filtering or human review. Neither a unique catalogue name nor a high Science Score establishes that an occurrence is a software mention.

The existing `/api/v1/projects/names` endpoint remains a flat list of lowercase strings. Use the structured endpoint when the consumer needs identities or evidence. The [OpenAPI definition](../openapi/api/v1/openapi.yaml) describes the response schema; [package discovery](package-discovery-and-ranking.md) and [citation metadata](citation-metadata-and-discovery.md) describe how the underlying records are collected.

## Context for a candidate

`GET /api/v1/projects/{id}/search_context` returns stored context for one candidate identified by a seed. It uses the same visibility and scientific eligibility rules as the seed endpoint; missing, hidden, or below-threshold projects return 404. The bulk seed response stays unchanged.

The response includes `project_id`, `repository_url`, `updated_at`, and `last_synced_at`, followed by:

- `descriptions`: text from the project description, repository metadata, and CodeMeta.
- `languages`: the repository's primary language, Brief language names, and CodeMeta `programmingLanguage` values.
- `packages`: packages published by this project, with their IDs, PURLs, registry, ecosystem, names, descriptions, and languages.
- `dependencies_indexed_at`: the last completed dependency indexing time, or null.
- `direct_dependencies`: indexed direct dependencies, with IDs, names, ecosystems, PURLs, source, manifest occurrences, and update timestamps.
- `repository_provenance`: the repository URL and stored `fork`, `source_name`, `mirror_url`, and repository `last_synced_at` claims, each with its source field. Absent fields are omitted; explicit null and false values are retained. Source names belong to the host in `repository_url`.
- `package_manifests`: selected R `DESCRIPTION` claims grouped by file path, with revision, SHA-256 digest, retrieval time and file URL. Each entry includes sourced `names`, `titles`, `descriptions`, `urls` and `bug_reports` arrays.

Names, descriptions, and languages are arrays of evidence objects. For example:

```json
{"value": "Python", "source": "repository.language"}
```

Values retain their original case. The same value can appear with several sources. Package metadata uses the same identity grouping as search seeds: records with the same normalized PURL share an entry, while distinct registry identities and forks remain separate. Package descriptions and languages come from linked package metadata and legacy package records stored on the project.

R manifest claims come from `Package`, `Title`, `Description`, `URL` and `BugReports`, collected during repository scans. Folded text is joined and multiple URLs are retained; R expressions are never evaluated. These claims remain separate from confirmed package identities. Declared URLs do not establish a mirror relationship or registry membership. A failed file read retains earlier evidence with its original revision and retrieval time. Both context additions are included in the SQLite export's `project_contexts` JSON.

Dependencies come from the saved dependency index, including records that have no resolved package ID or PURL. Each occurrence can include `filepath`, `manifest_kind`, `requirements`, `kind`, and `optional`. These distinguish development and optional dependencies from runtime requirements where source metadata supplies that detail. Dependencies belong to the project; they are not assigned to every package it publishes.

Brief's manifest paths are retained as occurrence filepaths. Repeated declarations in different files remain separate occurrences of one dependency identity, including when their requirements are identical.

Each dependency also includes `resolved_package`, or null when no package has been linked. This contains the linked package's `id`, `name`, `purl`, `registry` and `metadata_lookup`. The dependency's original name, ecosystem and PURL remain separate source claims; a resolved PURL does not replace a missing or conflicting source PURL.

`metadata_lookup` is also present in package API responses. Its `status` is `unchecked` until a lookup outcome has been stored, or the saved `matched`, `missing`, `unavailable`, `ambiguous`, `transient_error` or `failed` state. `checked_at` dates the last lookup and `retry_at` gives the scheduled retry time when present. `source_url` refers to the Packages API record when one has been matched, and `source_updated_at` dates that upstream metadata. A later unavailable or failed lookup can coexist with retained metadata from an earlier match. These states describe metadata availability rather than whether software exists or a paper refers to it.

The request reads stored metadata without fetching or indexing it. Empty arrays indicate missing evidence, rather than proof that a project has no dependencies or packages. Check `dependencies_indexed_at` before interpreting an empty dependency list. Context can help assess a text match, but it does not establish that a paper used the software.

## Search and lookup

The main search box uses `/projects/search`. It matches project names and repository URLs, plus indexed aliases and published package names. Matching is case insensitive and treats `%` and `_` literally. Complete historical repository URLs also match their indexed aliases. Results include visible projects with a positive Science Score, retain the keyword and language filters, and sort by combined science and ranking score with project ID breaking ties.

Confirmed linked Wikidata labels and aliases contribute names to the shared index and seed exports. Each name records its language, source field, catalogue record and project link in `name_evidence`. Ambiguous links contribute no names; when several confirmed projects share a name, they remain separate results. A failed source refresh retains names from the last retrieved record, while a missing record removes them on index refresh.

`GET /api/v1/software/lookup?q=orbdot&kind=name` finds exact normalized names or identifiers. Supported kinds are `name` (the default), `repository_url`, `homepage_url`, `doi`, `purl`, `rrid`, `wikidata`, `biotools`, `ascl`, and `swmath`. Names use lowercase Unicode NFC. DOI resolver URLs are accepted, URL paths retain case, and PURLs are normalized without a version or subpath. Identifier extraction and lookup share normalization; for example, `kind=rrid&q=rrid:scr_015687` queries `SCR_015687`.

`GET /api/v1/software/search?q=orbit` finds names containing the supplied text, including project names, aliases, and published package names. Search requires at least three characters. Matching is case insensitive and literal, so `%` and `_` are ordinary characters. Results are ordered by project ID, without relevance or confidence scores.

Both endpoints return `query`, `kind`, `match`, `projects`, and `next_after_id`. Each project contains the same identity fields as the seed endpoint, plus `indexed_at`, with only matching seeds and packages. A PURL match retains the matching package identity and has an empty `seeds` array. Sources and citation relations retain their existing meaning; forks and projects with shared names remain separate candidates.

Set `limit` between 1 and 25 (default 10). Pass `next_after_id` as `after_id` with the same query and kind until it is null. The cursor is a project ID. The result is a live view: metadata updates can change matches between pages, and a page can be empty while still returning a cursor if indexed candidates no longer match their current metadata. A missing result does not prove a project is absent from Science.

These routes only read stored data. Names and identifiers are indexed on the `projects` table in `search_identifiers` (JSONB), with `search_names` for substring search and `search_indexed_at` for freshness. The index covers positive-score projects for main search; the software API and seed export retain their scientific threshold of 20. PostgreSQL GIN indexes support exact containment and trigram searches. Committed project metadata, published package, repository alias and external identifier changes queue index refreshes, including bulk registry imports. Other bulk writes that bypass callbacks require a reindex. API evidence is extracted from current metadata for the selected page; main-search aliases reflect the last completed index refresh.

After deploying the migration, populate the fields once from the configured Science database:

```sh
RBENV_VERSION="$(cat .ruby-version)" /opt/homebrew/bin/rbenv exec bundle exec rake search_seeds:index
```

The task reads projects in batches of 250 and prints progress with the last project ID. Use `LIMIT=1000` for a bounded run or `AFTER_ID=12345` to resume after a reported ID. It is safe to rerun and does not fetch upstream metadata. Lookup coverage is incomplete until the backfill finishes; no SQLite file is needed by API or MCP users.

## Local SQLite export

`search_seeds:export` writes the same seed data directly from the configured local database into a SQLite file. It uses `ProjectSearchSeeds` for extraction, retaining the API's eligibility rules and provenance. The development and test bundle includes the `sqlite3` gem; run `bundle install` through the project's Ruby setup after updating dependencies.

On a local checkout configured with rbenv, run:

```sh
RBENV_VERSION="$(cat .ruby-version)" /opt/homebrew/bin/rbenv exec bundle exec rake search_seeds:export
```

The default output is `tmp/search-seeds-YYYYMMDDTHHMMSSZ.sqlite3`, with a UTC timestamp. Set `OUTPUT` to choose a path and `LIMIT` to export the first N eligible projects in ID order:

```sh
OUTPUT=tmp/search-seeds-preview.sqlite3 LIMIT=1000 RBENV_VERSION="$(cat .ruby-version)" /opt/homebrew/bin/rbenv exec bundle exec rake search_seeds:export
```

Omit `LIMIT` for the full eligible catalogue. The task prints progress to stderr and a JSON summary to stdout with the output path, snapshot ID, and counts. It refuses to overwrite an existing path. Only a completed, checked database appears at the requested filename; failures remove the temporary export.

PostgreSQL reads run in a read-only, repeatable-read transaction, with projects loaded in batches of 250. This keeps records and their associations consistent while other processes update the source database. The transaction remains open while source records are exported, so use the local database for large runs. Creating the SQLite file does not fetch upstream metadata or upload anything.

The file has these tables:

| Table | Contents |
| --- | --- |
| `metadata` | JSON values keyed by name: schema version, snapshot ID, start and completion times, selection rules, extractor source digest, isolation mode, and counts |
| `projects` | Project IDs, repository URLs, Science Scores, and source timestamps |
| `packages` | Package entries associated with projects, including nullable local package IDs and PURLs |
| `seeds` | Project and package seeds with original values, normalized values, sources, relations and optional name/identifier evidence |
| `project_fields` | Saved OpenAlex field assignments, names, domains, and confidence scores |
| `project_contexts` | One row per project, with the context endpoint's JSON response in `data` |
| `clues` | Deduplicated literal search strings, matching rules, ambiguity flags and combined start years |
| `clue_seeds` | Each clue's source seed IDs and the variant rule that emitted it |

`packages.id` is a row ID within this snapshot. `packages.package_id` is the local Science package ID and can be null. `seeds.package_entry_id` points to the snapshot package entry; null identifies a project-level seed. Preserve `project_id` when joining records, because the same software name can occur under multiple projects.

Schema version 2 is stored both in `metadata` and SQLite's `PRAGMA user_version`. Exports include `project_contexts`, identifier evidence, search years and literal clue tables. Projects and packages retain the API's `search_year` JSON and expose its `suggested_start_year` as a nullable integer column. Seeds retain optional `identifier_evidence` as JSON. Extractor and common-word list digests identify the code and data used for extraction. Snapshot IDs identify individual exports; project timestamps retain their source meaning and do not indicate when the export ran.

The context table has an indexed `project_id` primary key. Retrieve the same JSON as the endpoint with `SELECT data FROM project_contexts WHERE project_id = 123`. SQLite JSON functions also support queries over the evidence, for example:

```sql
SELECT c.project_id, json_extract(d.value, '$.name') AS dependency,
       json_extract(d.value, '$.purl') AS purl
FROM project_contexts c, json_each(c.data, '$.direct_dependencies') d
WHERE c.project_id = 123;
```

Indexes support lookups by seed type and normalized value, project, package ID, PURL, repository URL, and field. For example, find every candidate for a normalized name:

```sql
SELECT s.project_id, p.repository_url, k.package_id, k.purl, s.source, s.relation
FROM seeds s
JOIN projects p ON p.project_id = s.project_id
LEFT JOIN packages k ON k.id = s.package_entry_id
WHERE s.type = 'name' AND s.normalized_value = 'stats';
```

Normalize names with Unicode NFC and lowercase before querying, as for the API. SQLite's built-in `lower()` and `NOCASE` only cover ASCII case folding, so they do not replace the seed normalization rules for non-ASCII names. URL path case and PURL identity are preserved by exact lookup.

The `registry_coverage`, `field_coverage`, and `name_collisions` views provide summaries without loading the dataset into an application. Registry grouping and comparisons use `NOCASE`, so capitalized registry labels match. A shared name means it appears under multiple projects or package entries; repeated provenance for one identity does not increase those counts.

```sql
SELECT * FROM registry_coverage ORDER BY package_entries DESC;
SELECT * FROM field_coverage ORDER BY projects DESC;
SELECT * FROM name_collisions ORDER BY projects DESC, normalized_value LIMIT 20;
SELECT value FROM metadata WHERE key = 'counts';
```

The counts include projects without packages, DOI seeds, or OpenAlex field assignments, and package entries without local IDs or PURLs. Field coverage uses saved project classifications and can count one project in several fields. These measures describe coverage of the exported population, rather than mention-detection accuracy.

## Literal search list

`clues` contains one row per literal string and case rule across all sources and entities. `clue_seeds` maps each row back to every original seed, including its original spelling, source, relation and candidate identity. `clue_candidates` provides distinct project and package candidates with their individual search years. Repeated evidence does not create extra searches or merge software identities.

The export supports these finite variants, recorded in `metadata.literal_variants`:

- Names: Unicode NFC and lowercase, with each run of Unicode whitespace replaced by one ASCII space and outer whitespace removed. `Climate\t Lab` and `Climate Lab` both emit `climate lab`. Punctuation remains unchanged, so `scikit-learn` does not create `scikit learn`.
- Repository and homepage URLs: the normalized URL without its scheme. `https://EXAMPLE.org/Docs` emits `example.org/Docs`, which also occurs in the HTTP variant. GitHub repository URLs such as `https://github.com/Owner/Repo` emit a lowercase, case-insensitive clue. This applies to `github.com` and `www.github.com`, standard HTTP(S) ports, and an owner/repository path with an optional trailing slash and no query or fragment. Known navigation routes, deeper paths, encoded path segments and other hosts retain case; `/Docs` and `/docs` remain separate there. The `www` prefix, trailing slash and `.git` suffix remain in the literal. Original URL spelling and source links are retained in `seeds` and `clue_seeds`.
- DOIs: the bare lowercase identifier. This literal also matches within a `doi:` prefix or HTTP(S) resolver URL.
- RRIDs: the bare identifier. This literal also matches within `RRID:SCR_015687` and `RRID: SCR_015687`.
- Wikidata and bio.tools: the bare identifier, which also occurs within the registry record URL.
- ASCL and swMATH: the scheme-prefixed identifier and HTTPS registry record URL. Bare numeric identifiers are omitted from this search list.

Case-insensitive literals are stored in lowercase NFC with `case_sensitive = 0`. URL variants use `case_sensitive = 1` except for the GitHub repository URLs described above. A string with different case rules has separate rows. Prefixes and resolver forms already covered by an identifier literal do not create extra searches. No wildcard, stemming, arbitrary punctuation substitution or regular-expression expansion is performed.

Ambiguous clues remain in the list with all candidate and source links. `shared_name` reuses `name_collisions` and also detects collisions introduced by whitespace folding. `ordinary_word = 1` identifies case-insensitive literals in the checked-in `config/search_seed_common_words.txt` review list or the English dictionary extract described below. Null means unassessed. `word_evidence` is a JSON array naming each matching source, its language and its kind (`reviewed_list` or `dictionary`); an empty array is not evidence that a string is unambiguous. These checks apply equally to repository slugs, package names and bare identifiers, without measuring their frequency in paper text.

`short_name` flags names under three characters. `punctuation_only` flags literals containing no Unicode letters or numbers, including long separators and symbol-only names. `generic_name` flags exact normalized names in `config/search_seed_generic_names.txt`, such as `About`, `Content` and `Method`, and reviewed ambiguous abbreviations. These include `GIS` (geographic information systems or case-folded `GIs` in climate text), `HCP` (host cell protein) and `ALS` (angular leaf spot). A source can correctly attach one of these names to software while an occurrence refers to something else. This classification does not assert that the name was derived from a heading, and does not change the stored name.

`non_specific_url` flags roots, namespace-only paths and known navigation pages on GitHub, GitLab.com, Bitbucket.org and Codeberg.org. For example, `github.com/owner` is flagged while `github.com/owner/repo` is retained without this flag. Query strings do not supply a missing repository path. Dedicated homepages such as `project.example/` and `project.github.io/` are not flagged merely for lacking a path. A zero flag means the rule did not identify a non-specific URL; it does not verify a repository's existence or cover every hosting service.

`ambiguous` is true when any flag is set, allowing consumers to run those clues separately or require supporting context. Flags do not establish whether an occurrence is a software mention or which candidate it identifies. Schema version 2 is retained; older snapshots may lack the added columns and views. Consumers can inspect `PRAGMA table_info(clues)`, `PRAGMA table_info(seeds)` and `sqlite_master` before using them.

The dictionary extract contains 81,556 lowercase, letters-only entries from the [English Speller Database](https://github.com/en-wl/wordlist). It uses size 60, American and British spellings, variant level 1, with special categories and abbreviations excluded. This includes scientific words such as `substrate`, `outlier` and `plasticity`. Month and weekday names are included separately in the reviewed word list, since the lowercase-only dictionary filter excludes capitalized entries such as `December`. `config/search_seed_dictionary/source.json` records the upstream commit, extraction command, filtering steps and SHA-256 digest; `COPYRIGHT.txt` in that directory contains the upstream attribution and permission notice. Dictionary membership is evidence of an English word, not a frequency estimate or a judgement about a software mention. No dictionary evidence is supplied for other languages.

To reproduce the extract, check out the revision recorded in `source.json` in the upstream repository, run `make scowl.db`, then the recorded `scowl word-list` command. Keep entries consisting entirely of Unicode letters whose spelling is already lowercase, normalize to NFC, deduplicate, sort and write one entry per line. The export checks the resulting file against its recorded digest. `metadata.word_sources` includes source descriptions, digests and the dictionary's copyright notice; reviewed and dictionary evidence remain separate, and the generic-name list has its own digest.

Each clue's `suggested_start_year` is the minimum candidate year when every candidate has a known bound. Any unknown candidate makes the combined bound null. All original bounds and evidence remain available through `clue_candidates`.

For example, recover a clue's evidence and candidate links:

```sql
SELECT c.value, c.case_sensitive, s.project_id, s.package_entry_id,
       s.type, s.value, s.source, s.relation, s.identifier_evidence, cs.variant
FROM clues c
JOIN clue_seeds cs ON cs.clue_id = c.id
JOIN seeds s ON s.id = cs.seed_id
WHERE c.value = 'star';
```

Export counts include `search_strings`, `clue_seed_links` and `ambiguous_search_strings`. Compare search strings with seed rows to measure the effect of deduplication and variant expansion separately from candidate coverage.

`clue_candidate_summary` reports distinct `project_candidates` and `package_candidates` for every clue, plus `fork_projects`, `nonfork_projects` and `unknown_fork_projects`. Repeated source evidence does not increase these counts. Package counts refer to exported package entries, which may lack a PURL or local package ID. Both the view's `count_scope` and `metadata.candidate_count_scope` say `exported_projects`: counts are limited to the selected export population and must not be presented as full-catalogue counts for a sample.

`clue_candidate_details` retains each candidate and adds its repository URL, stored fork flag, upstream `fork_source_name` and `mirror_url` from the exported project context. An absent or non-boolean fork claim remains unknown. Source names are relative to the repository's host; they are claims about an upstream relationship, not proof that candidates are interchangeable. No projects are merged, and an upstream project need not be present in the export.

```sql
SELECT c.value, s.* FROM clue_candidate_summary s
JOIN clues c ON c.id = s.clue_id
WHERE s.project_candidates > 1
ORDER BY s.project_candidates DESC, c.value;

SELECT project_id, repository_url, fork, fork_source_name, mirror_url
FROM clue_candidate_details
WHERE clue_id = 123;
```
