# Citation metadata and repository discovery

Project sync downloads CITATION, CodeMeta, and Zenodo files identified by repository metadata. The saved content supports Science Score evidence, citation export, OpenAlex work lookup, and discovery of related software repositories.

## Stored files

The repository record from repos.ecosyste.ms provides detected paths for `CITATION.cff`, `codemeta.json`, and `.zenodo.json`. Sync fetches those paths through archives.ecosyste.ms and stores their contents in `projects.citation_file`, `projects.codemeta`, and `projects.zenodo`. CodeMeta also has a raw-repository fallback at `codemeta.json` when the detected archive path is absent or unreadable.

Citation content is treated as CFF only when it begins with a `cff-version` key. Other citation content is scanned as BibTeX when it begins with an entry such as `@software{...}`. Invalid CFF, CodeMeta JSON, or Zenodo JSON returns no parsed metadata and logs the project ID and URL rather than failing the page request.

`Project#exportable_metadata` returns parsed CodeMeta when available, with a CFF-to-CodeMeta conversion as its fallback. BibTeX and APA-like citation exports currently require valid CFF content.

## DOI candidates

OpenAlex work ingestion uses selected publication references rather than every identifier in each metadata file. The source path is retained with each accepted DOI:

| File | Accepted DOI locations |
| --- | --- |
| CFF | `preferred-citation.doi` and DOI identifiers on the preferred citation |
| BibTeX | `doi` fields and `doi.org` URLs |
| CodeMeta | Values nested below `referencePublication` |
| Zenodo | DOI related identifiers whose relation is `isDocumentedBy` |

Each candidate records a source path such as `citation_cff.preferred-citation.doi` or `zenodo.related_identifiers.isDocumentedBy`. The OpenAlex assignment keeps this source together with the normalized DOI, so two metadata files that cite the same work remain separate evidence rows. README DOI and arXiv extraction follows the separate path described in [OpenAlex taxonomy and work ingestion](openalex-ingestion.md).

## Repository URL candidates

Repository discovery reads a broader set of fields. Software references and root metadata can both supply candidates:

| File | Accepted repository locations |
| --- | --- |
| CFF | `repository-code`, `repository`, and `url` on the root record, preferred citation, and references |
| BibTeX | HTTP and HTTPS URLs in the entry |
| CodeMeta | `codeRepository`, `relatedLink`, `sameAs`, `citation`, and `url` values, including nested arrays and objects |
| Zenodo | Every URL in `related_identifiers`, with its relation retained in the source name |

`MetadataRepositoryImporter` scans visible scientific projects with at least one saved citation or metadata file. It processes 100 source projects per batch and de-duplicates normalized candidate URLs for the duration of the run.

GitHub URLs are reduced to `https://github.com/owner/repository`. Configured GitLab hosts retain groups and subgroups but remove paths beginning with markers such as `/-/blob`, `/tree`, `/issues`, or `/releases`. The host list combines local GitLab `Host` rows, `gitlab.com`, and the GitLab catalog returned by repos.ecosyste.ms.

The normalizer rejects malformed URLs, embedded credentials, GitHub site routes, placeholder owners or repository names, and hosts outside the GitHub or configured GitLab set. Bitbucket links are counted separately and skipped. All accepted URLs are lowercased.

Before creating a project, the importer checks exact saved URLs and repository `previous_names`. It also skips links back to the source project. A new `Project` contains only the normalized URL and is immediately queued through `SyncProjectWorker`.

## Running repository discovery

The importer runs daily at `01:00`, after the main discovery task and before the weekly or daily classification jobs. Use a dry run to inspect counts without creating projects or enqueuing sync jobs:

```bash
DRY_RUN=true bundle exec rake projects:import_metadata_repositories
```

Run the write path with the following command. Missing repositories are created and queued for sync:

```bash
bundle exec rake projects:import_metadata_repositories
```

The result reports source projects, links, normalized repositories, GitHub and GitLab counts, existing records, previous-name aliases, new records, self-links, Bitbucket links, skipped values, and failures. In a dry run, `new` can increase while `created` remains zero.

Inspect the extracted evidence for one project in a Rails console. Both arrays retain the metadata source path:

```ruby
project = Project.find(476); pp project.open_alex_metadata_doi_candidates; pp project.metadata_repository_url_candidates; nil
```

The repository importer only creates and queues missing projects. Their metadata and scores arrive later through the sync pipeline described in [Project ingestion and sync](project-ingestion-and-sync.md).
