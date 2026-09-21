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
