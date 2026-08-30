# OpenAlex taxonomy and work ingestion

`open_alex:sync` refreshes the local OpenAlex topic hierarchy and associates projects with topics from scholarly works. These imported work topics are provenance-bearing labels used by project pages and classifier validation. Repository-text field predictions follow the separate process described in [OpenAlex field classification](openalex-field-classification.md).

## API access

`OpenAlexApiClient` requires `OPENALEX_API_KEY`. Topic pages use cursor pagination with 100 records per request. Work lookup normalizes DOI resolver URLs, percent encoding, case, trailing punctuation, and unmatched closing delimiters before sending batches of up to 100 DOIs.

Requests retry HTTP 429 and common 5xx responses twice with backoff. If OpenAlex rejects a work batch with HTTP 400, the client splits the batch until it isolates a single rejected DOI, logs that value, and continues with valid siblings. Other request failures raise and stop the current task. DOI-looking image URLs such as Zenodo badge SVGs are rejected before work lookup.

## Taxonomy refresh

The taxonomy importer downloads every topic page and de-duplicates rows by OpenAlex topic ID. A refresh must contain at least 4,000 topics before any database changes begin. This protects the active taxonomy from a truncated API response.

Valid topics are upserted in batches of 500 with their display name, description, keywords, subfield, field, domain, and OpenAlex update date. Topics absent from the completed response are marked inactive. Existing `ProjectOpenAlexTopic` records are retained, but classifiers and taxonomy pages select active topics.

## Work-label sources

After the taxonomy commits, the rake task runs four project-topic importers in order. Each source has its own scope and replacement set:

| Source | Project scope | Identifier source |
| --- | --- | --- |
| `joss_doi` | Visible JOSS projects with a paper DOI | `joss_metadata.doi` |
| `readme_doi` | Visible scientific projects whose README contains a DOI pattern | DOI references extracted from the README |
| `readme_arxiv` | Visible scientific projects whose README contains arXiv text or URLs | arXiv IDs converted to `10.48550/arxiv.*` DOIs |
| Metadata provenance | Visible scientific projects with CITATION, CodeMeta, or Zenodo content | Selected publication DOI fields from those files |

Metadata sources retain paths such as `citation_cff.preferred-citation.doi` rather than the generic `metadata_doi` task name. Their extraction rules are documented in [Citation metadata and repository discovery](citation-metadata-and-discovery.md).

Each importer batches source projects in groups of 50, groups shared DOIs into one OpenAlex lookup, and imports every valid topic returned for each matched work. `primary_topic` records the work's primary topic, while the score is OpenAlex's topic score. A single work can produce several assignment rows for one project, and the same work can be linked through several provenance sources.

The unique assignment key is project, topic, source, and source identifier. `openalex_work_id` keeps assignments for separate works distinguishable in reports.

## Identifier safeguards

Funding organization DOIs beginning with `10.13039/` remain available in project data but are excluded from scholarly work topics. A sync also removes older assignments that used those funding identifiers.

README ingestion skips a project when its combined normalized DOI and arXiv list exceeds ten identifiers. The importer clears that project's prior assignments for the affected README source, which keeps large bibliography lists out of project labels.

Replacement depends on the OpenAlex response. When a DOI resolves to a work, the importer replaces prior assignments for that project and source, even when the work now has no topics. When OpenAlex returns no work for a DOI, prior assignments remain because the missing response cannot establish a replacement set.

Metadata assignment replacement covers the `citation_bib.`, `citation_cff.`, `codemeta.`, and `zenodo.` source prefixes together. JOSS, README DOI, and README arXiv rows are replaced independently.

## Running the sync

The full task runs daily at `05:00`. The API key must be present in the process environment:

```bash
OPENALEX_API_KEY=... bundle exec rake open_alex:sync
```

The task prints taxonomy counts followed by project, identifier, match, assignment, and safeguard counts for each source. The taxonomy and each source commit separately, so a later failure does not roll back earlier completed stages.

Inspect saved work labels for one project in a Rails console. Each line includes its work and source provenance:

```ruby
project = Project.find(476); project.project_open_alex_topics.includes(:open_alex_topic).order(score: :desc).each { |assignment| puts "work=#{assignment.openalex_work_id.inspect} topic=#{assignment.open_alex_topic.display_name.inspect} score=#{assignment.score.inspect} primary=#{assignment.primary_topic?.inspect} source=#{assignment.source.inspect} identifier=#{assignment.source_identifier.inspect}" }; nil
```

Inspect aggregate source coverage without loading assignment rows. The query groups distinct projects for each provenance source:

```ruby
ProjectOpenAlexTopic.group(:source).distinct.count(:project_id).sort.each { |source, count| puts "source=#{source.inspect} projects=#{count.inspect}" }; puts "active_topics: #{OpenAlexTopic.active.count.inspect}"; nil
```

## Validation labels

`open_alex:validation` treats imported work topics as evaluation labels for repository-text predictions. The report compares top-one and top-five matches at topic, subfield, field, and domain levels without saving predictions.

```bash
LIMIT=500 bundle exec rake open_alex:validation > tmp/open_alex-validation.csv
```

The field materializer runs at `06:00`, one hour after ingestion, and reads the refreshed active taxonomy. Its scoring and replacement behavior are documented in [OpenAlex field classification](openalex-field-classification.md).
