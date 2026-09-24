# Science cohort lookup and export

These endpoints read stored observations without creating records, scheduling
syncs or calling external APIs. Their inputs identify different populations:
package lookup describes scientific dependency use, while repository lookup
finds recorded projects, including projects below the scientific-score threshold.

## Package lookup

Send `POST /api/v1/packages/bulk_lookup` with a JSON body:

```json
{"purls":["pkg:pypi/numpy@2.0.0","pkg:npm/%40scope/name"]}
```

The request accepts 1 to 100 strings of at most 2,000 characters. It uses the
stored package PURL normalization: versions and subpaths are removed, qualifiers
are retained, and package-type normalization follows the PURL parser. It also
accepts an unescaped npm scope. Invalid inputs return HTTP 400.

The response is an array with the same fields as the package listing, ordered by
package ID. Duplicate inputs produce one stored package record. Unknown PURLs
are omitted; an entirely unmatched request returns `[]`. A stored package with
no direct scientific dependencies returns `scientific_projects_count: 0`.
Packages excluded by the listing's publisher-score filter remain discoverable.

## Repository lookup

Send `POST /api/v1/projects/bulk_lookup` with `repository_urls`, an array of 1 to
100 URL strings. Matching uses the existing repository URL normalizer and the
indexed, case-insensitive project and alias URL columns. Credentials are rejected.
Previous names must have been processed by the repository alias indexer.

Each input produces a result containing `input_url`, `normalized_url` and
`matches`. Each match contains a project summary and a `source` of `project.url`
or `repository_alias`. All matches are retained when an alias is shared by
several projects. Hidden projects are excluded. An empty matches array means
no stored match, which does not establish absence of scientific use.

## Stored Software Heritage evidence

`GET /api/v1/projects/{id}/swhids` returns the observed commit, typed revision and
directory identifiers, their archive check statuses and timestamps, and stored
origin visits. A project without observations returns `unchecked`; hidden or
unknown projects return HTTP 404. Local paths and command lines are excluded.

Calculation status and archive status are separate: calculating an identifier
does not establish that SWH stores it. `not_found`, `error` and `unchecked` remain
distinct. Origin visits can refer to older content or historical URLs. Compare
observation timestamps before comparing coverage, and treat `bytes_verified:
false` as no byte-retrieval verification by this endpoint.

## Reproducible exports

Run `bundle exec rake science_cohort:export OUTPUT=tmp/science-cohort.jsonl` to
capture visible scientific projects and ranked direct scientific dependencies
in one PostgreSQL repeatable-read, read-only transaction. `BATCH_SIZE` defaults
to 250 and accepts 1 to 1,000. The task streams records to disk and publishes the
completed file without overwriting an existing path.

Every JSON line has `type` and `data`. The opening `snapshot` records the selection,
start time and snapshot identifier. `project` records contain the search-seed
document and stored SWH evidence. `package` records contain identity, registry,
repository, publisher and scientific-use counts. The final `complete` record
contains the same snapshot identifier, completion time and record counts.
Standard output also reports the completed file's SHA-256.

Both populations use the same source snapshot, even if scores or repository
metadata change during export. Ranked dependency filters still apply, so absence
from the file does not establish absence of scientific use. Stored observations
retain their own check dates; the export time is not a new archive check.
The existing `search_seeds:export` SQLite format remains unchanged.
