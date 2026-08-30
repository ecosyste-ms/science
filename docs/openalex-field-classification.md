# OpenAlex field classification

`OpenAlexTopicClassifier` ranks repository text against the active OpenAlex topic taxonomy. `OpenAlexFieldClassificationImporter` turns those topic predictions into `Field` and `ProjectField` records for visible scientific projects. The classifier reads stored taxonomy data and project text; it does not use a project's DOI or saved `ProjectOpenAlexTopic` labels when making a prediction.

## Text inputs

The taxonomy comes from active `OpenAlexTopic` rows created by `open_alex:sync`. Each taxonomy term receives the highest applicable source weight:

| Taxonomy text | Weight |
| --- | ---: |
| Topic display name | 5 |
| Topic keyword | 4 |
| Subfield name | 2 |
| Field name | 1 |
| Topic description | 1 |

The project vector uses the same tokenization with separate source weights:

| Project text | Weight |
| --- | ---: |
| Project name | 5 |
| Project keyword | 5 |
| Project description | 4 |
| README | 1 |

Tokenization produces lowercase Unicode words and adjacent two-word terms. Words start with a letter and contain 3 to 40 letters or digits. The README is limited to its first 5,000 characters and passes through the JOSS vocabulary sanitizer, which removes code blocks, badges, images, citation material, and administrative sections such as installation and contribution instructions.

Common stop words and generic software terms such as `code`, `data`, `package`, `project`, `python`, `software`, and `tool` are discarded. A term found in more than one source keeps its highest source weight.

## Topic and field ranking

Topic terms receive an inverse document-frequency multiplier across all active topics:

```text
idf(term) = log((topic_count + 1) / (document_frequency + 1)) + 1
```

Each topic score is the normalized dot product of the project vector and the weighted topic vector. Scores fall between zero and one. Results are ordered by descending score, with the OpenAlex topic ID breaking ties.

The classifier keeps the five highest-ranked topics before grouping them by OpenAlex field. Several of those topics can belong to the same field, so a project can finish with fewer than five fields. A field receives the score of its highest-ranked topic, up to ten distinct matched terms, and up to five contributing topic IDs.

The classifier applies no minimum score threshold, so any retained term match can produce a topic prediction. A project with no retained taxonomy match receives no fields. Review raw scores and matched terms when changing weights, tokenization, or the topic cutoff.

## Rebuilding stored classifications

The materializer selects `Project.visible.scientific` and processes projects in batches of 500. Before processing projects, it synchronizes distinct active OpenAlex fields into `fields` using the IDs, names, and domains stored on the topics. A same-name legacy field is upgraded in place, and its old `ProjectField` rows are removed before new classifications are written.

Each project batch replaces its existing classifications for active OpenAlex fields inside a transaction. `project_fields.confidence_score` stores the raw field score. `project_fields.match_signals` stores `matched_terms` and `topic_ids`.

Run a limited sample while developing:

```bash
LIMIT=500 bundle exec rake open_alex:classify_fields
```

Run the full rebuild after an OpenAlex taxonomy sync:

```bash
bundle exec rake open_alex:classify_fields
```

Progress is printed after every 500 projects. The final line reports field, project, classified-project, and classification counts. During the first field sync, a limited run can remove legacy `ProjectField` rows outside its selected project scope when it upgrades same-name fields. Use `LIMIT` only against a development database.

`app.json` schedules `open_alex:sync` at `05:00` each day and `open_alex:classify_fields` at `06:00`. The one-hour gap lets the field rebuild use the latest active taxonomy.

## Inspecting a project

This Rails console snippet prints the stored rankings and evidence for project 476:

```ruby
project = Project.find(476); project.project_fields.includes(:field).select { |classification| classification.field.openalex_id.present? }.sort_by { |classification| -classification.confidence_score }.each { |classification| puts "field=#{classification.field.name.inspect} score=#{classification.confidence_score.inspect} signals=#{classification.match_signals.inspect}" }; nil
```

The project API returns the same ranked fields as `id`, `name`, `domain`, and `score` values. Field IDs remain canonical OpenAlex IDs in the API, while the web pages use name-based slugs.

## Validation report

`open_alex:validation` compares repository-text predictions with the OpenAlex topics already imported for linked works. It writes one CSV row per project and OpenAlex work to standard output, then prints aggregate coverage and top-one or top-five match rates for topics, subfields, fields, and domains to standard error.

```bash
LIMIT=500 bundle exec rake open_alex:validation > tmp/open_alex-validation.csv
```

The imported work topics are evaluation labels only. Running the validation report does not save classifier predictions or change project classifications.
