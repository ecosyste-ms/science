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
  "relation": "software"
}
```

`type` is one of `name`, `repository_url`, `homepage_url`, or `doi`. `value` retains the trimmed source spelling; DOI values contain the extracted identifier. `normalized_value` is intended for matching:

- Names use Unicode NFC and lowercase, preserving punctuation. There is no stemming or word-boundary policy.
- DOIs are lowercase.
- URLs have lowercase schemes and hosts, with path case preserved. Repository history may already have been normalized before storage.

`source` identifies the metadata field, such as `codemeta.alternateName` or `citation_cff.preferred-citation.doi`. The same value can occur several times with different sources. Preserve those evidence records even if the matcher searches the string only once.

Each package contains `package_id`, `purl`, `registry`, `ecosystem`, and `seeds`. Linked local package records have a `package_id`; unmatched package metadata stored on the project has `package_id: null`. PURLs omit version and subpath, and may also be `null` when missing or invalid. Registry and ecosystem fields can be missing on older metadata.

Package metadata with the same normalized PURL is combined within the project, retaining seeds from both sources. For example, `package.name` and `project.packages[0].name` can appear under one package. Without a matching PURL, entries remain separate. The array position in a source path refers to the stored metadata at extraction time and should not be used as a permanent identifier.

## Sources and relationships

Project seeds come from the project name and repository URL, repository homepage and rename history, and selected citation metadata. CFF contributes the root title, URL, code repository, DOI identifiers, and preferred-citation DOIs. CodeMeta contributes names, alternate names, homepage, code repository, identifiers, and reference-publication DOIs. Zenodo contributes its root DOI and documentation DOIs, while JOSS contributes its publication DOI. BibTeX citation content supplies DOI fields and DOI resolver URLs.

Package seeds contain names and homepages from linked package records and package metadata stored on the project. Arbitrary links in citation references, CodeMeta related links, and Zenodo references are not promoted to software aliases. Invalid optional metadata is skipped so usable seeds can still be returned.

The `relation` field preserves distinctions needed when evaluating a hit:

| Relation | Meaning |
| --- | --- |
| `software` | A name, location, or identifier associated with the software record |
| `publication` | A publication DOI from JOSS, CodeMeta reference publications, or Zenodo documentation links |
| `preferred_citation` | A DOI from a CFF preferred citation, whose target may be software or a publication |
| `citation` | A DOI from BibTeX citation content, without an inferred target type |
| `reference` | A root DOI identifier from a CFF record typed as a dataset |

These relationships describe source metadata. A publication DOI hit can identify a citation target, but it does not establish that the paper used the software. Repository and package metadata can also contain incorrect associations; provenance makes those claims inspectable.

## Using seeds in a detector

Build a lookup from each normalized seed to all candidate project and package identities. Names can collide across unrelated projects and registries, and forks can retain the same name. Keep the complete repository URL and owning identity when resolving those cases. A package-level seed can support a package candidate; a project-level seed alone cannot select a registry package or release.

Treat seed strings as literal search input and escape them if the matcher uses regular expressions. Preserve surrounding text and the matched seed's provenance for later filtering or human review. Neither a unique catalogue name nor a high Science Score establishes that an occurrence is a software mention.

The existing `/api/v1/projects/names` endpoint remains a flat list of lowercase strings. Use the structured endpoint when the consumer needs identities or evidence. The [OpenAPI definition](../openapi/api/v1/openapi.yaml) describes the response schema; [package discovery](package-discovery-and-ranking.md) and [citation metadata](citation-metadata-and-discovery.md) describe how the underlying records are collected.

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
| `seeds` | Project and package seeds with original values, normalized values, sources, and relations |
| `project_fields` | Saved OpenAlex field assignments, names, domains, and confidence scores |

`packages.id` is a row ID within this snapshot. `packages.package_id` is the local Science package ID and can be null. `seeds.package_entry_id` points to the snapshot package entry; null identifies a project-level seed. Preserve `project_id` when joining records, because the same software name can occur under multiple projects.

Schema version 1 is stored both in `metadata` and SQLite's `PRAGMA user_version`. The extractor digest identifies the source file used to derive seeds. Snapshot IDs identify individual exports; project timestamps retain their source meaning and do not indicate when the export ran.

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
