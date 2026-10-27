# Science Score

Science Score is a stored estimate of whether a repository contains research software. `ScienceScoreCalculator` returns a value from 0 to 100 with an evidence breakdown, and `Project#update_science_score` writes both values to `projects.science_score` and `projects.science_score_breakdown`.

`Project.scientific` starts at 20 and `Project.highly_scientific` starts at 75. Projects with any positive score appear in the general project browser and search. The 20-point threshold controls OpenAlex field classification, metadata repository discovery, institutional owner pages, and several import paths. Brief scanning accepts visible projects with a positive score, publishers used directly by scientific projects, and confirmed Wikidata, bio.tools, ASCL, swMATH, RRID or DOI matches because a scan can add evidence and raise the score.

## When scores change

A normal project sync fetches repository, package, dependency, commit, README, issue, citation, CodeMeta, and Zenodo data before calculating the score. A successful Brief scan also recalculates it because detected languages and tools can add research-tooling evidence.

Project paper imports recalculate the score after saving resolved references. Score changes queue a search-index update, so projects that reach 20 become eligible for software lookup, search and MCP context once indexing finishes.

Confirmed ASCL, bio.tools, swMATH and RRID matches remain eligible for routine refresh at zero points. Their sync also queues a missing Brief scan. Eligibility requires a matched link and a previously retrieved record with status `ok` or `error`; source, status and match status comparisons are case-insensitive. Identifier membership does not itself add score points. Completed scans and stored scan errors retain their existing retry rules.

`BriefScanEnqueuer.new(rescan: true)` selects confirmed identifier matches from all six sources with scores strictly below 20, including completed scans and stored errors. The worker rechecks the score and identifier after taking its project lock. These jobs rerun Brief and save a recalculated score; existing SWHIDs are retained. Normal scan jobs still skip completed scans and stored errors. A failed rescan records its error using the normal scan failure behavior.

Views and API responses read the saved breakdown. They do not calculate a new score during a request, so changed weights take effect only after the project is scored again.

`projects:rescore` runs every minute and queues a pass over up to 1,000 visible projects using stored evidence. It includes zero and unscored projects, saves a Redis cursor, and starts another pass after reaching the end. Each batch stops after 45 seconds between projects; failed projects are logged and revisited on the next pass. Only one batch runs at a time, with per-project row locks and query timeouts. Unchanged scores and breakdowns do not write the project or enqueue search updates. The Redis hash `science:production:score-refresh` records the cursor, last batch counts, check time and last completed pass.

## Non-JOSS projects

The standard path adds weighted signals. The table shows each signal's maximum point contribution. A fractional signal multiplies those points by its strength before the values are added.

```text
base score = sum(signal points * signal strength)
```

| Signal | Weight | Evidence |
| --- | ---: | --- |
| CITATION file | 16 | Stored citation file content |
| CodeMeta file | 13 | A reported CodeMeta filename or downloaded software metadata |
| Zenodo file | 15 | A Zenodo filename reported by repository metadata |
| Academic link | 8 | A recognized publication or archive host in the README |
| Academic committers | 5 | Fraction of committers matched to academic organization domains |
| Institutional owner | 10 | Organization owner matched to a research organization domain |
| Scientific registry | 7 | A package published through CRAN or Bioconductor |
| JOSS vocabulary | 13 | Vocabulary score of at least 30 from the active JOSS model |

These are fixed point contributions; removing a signal does not increase the others. Citation evidence accepts detected citation filenames or downloaded content. Structured BibTeX in the README supplies the half-strength citation signal (8 points) when the separate citation content is unstructured or absent. CodeMeta accepts a filename advertised by repository metadata or downloaded JSON containing a nonblank string `name` and a `SoftwareSourceCode` or `SoftwareApplication` type. Zenodo checks the advertised filename.

A project receives one 20-point reference contribution when it has a recognized publication or archive identifier, a research software review badge, or a resolved paper relationship. Identifiers are extracted from stored README and citation contents using the citation import parser: DOI, arXiv, PMID, ACL Anthology, OpenReview and Semantic Scholar Corpus IDs. DOI image paths, generic PDF links and title-only candidates do not qualify as identifiers. No resolver request or successful paper import is required.

Badge detection recognizes pyOpenSci's `peer-reviewed.svg` and Shields badges, rOpenSci's numbered `status.svg` and `stats.svg` badges, and JOSS paper status badges. Images linked to numbered pyOpenSci or rOpenSci review issues also qualify, including older shortened badge URLs. Presence in the README is sufficient; the detector does not fetch the badge or check acceptance status. The saved breakdown records the programme, badge URL and review identifier and URL where available.

Identifiers, badges and resolved papers share the same 20-point allowance. This replaces DOI, academic-link and half-strength BibTeX contributions, regardless of the number of references or badges. The saved breakdown retains overlapping signals with `duplicate_of` pointing to the credited signal. Full-strength CFF software metadata and other independent signals still count. Existing penalties apply afterwards. The rule is shared by model and software projects; a reference does not establish implementation or authorship, and a badge does not establish completed review. Imported JOSS metadata retains its separate scoring path.

Academic committer strength is the sum of matched organization strengths divided by the number of committers. An institutional owner uses the matched domain strength directly. ROR company records can identify an institution for owner browsing, but company domains are excluded from academic email evidence.

The vocabulary signal is described in [JOSS vocabulary scoring](joss-vocabulary.md). Its raw score and matched terms remain in the saved breakdown even though the Science Score treats it as a present or absent 13-point signal.

## Brief and dependency bonuses

Research tooling can add up to 20 points after the weighted signals. Strong evidence includes research-domain tool taxonomy, Snakemake, Nextflow, nf-core, MultiQC, Dockstore, or Fortran. DVC receives strength 0.7. Quarto, R Markdown, knitr, Jupyter, renv and targets receive strength 0.4. Generic development tools and testing, coverage, linting, type-checking and formatting categories do not contribute research evidence. Python development maturity and R/Julia package-development combinations add no points.

A tooling strength above 0.4 applies on its own. Strength 0.4 applies only when the JOSS vocabulary signal is also present. The bonus is `20 * strength`.

Scientific package evidence can add 8 points. A project receives the bonus when its own package is on the scientific dependency list or at least three dependencies match that list. One or two matching dependencies remain in the breakdown with strengths 0.4 or 0.7 but do not add the bonus.

## Negative indicators

Repository topics and names can reduce the score after bonuses. Strong indicators such as `awesome-list`, an `awesome-` repository name, `dotfiles`, homework, interview preparation, cheatsheets, and roadmaps apply an 80 percent penalty. Weak indicators such as tutorials, courses, templates, examples, demos and portfolios apply a 50 percent penalty. A strong match takes precedence when both tiers occur. A bare `awesome` topic and being a fork do not reduce the score.

```text
score after penalty = score before penalty * (1 - penalty)
```

The final value is rounded to two decimal places and capped at 100. The saved breakdown includes the matched negative indicators and the applied penalty.

## JOSS projects

A project with `joss_metadata` starts at 85 because JOSS acceptance includes editorial review and peer review. The JOSS path skips vocabulary scoring. Six metadata and institutional bonuses can raise the score before the 100-point cap:

| Signal | Bonus |
| --- | ---: |
| CITATION file | 5 |
| CodeMeta file | 3 |
| Zenodo file | 3 |
| DOI reference | 2 |
| Academic committers | 2 |
| Institutional owner | 3 |

Research-tooling bonuses, dependency bonuses, and negative-indicator penalties are not applied on the JOSS path. Those checks still appear in the saved evidence breakdown.

## Inspecting and recalculating

This Rails console block recalculates one project without saving, then prints its current stored score. The saved columns remain unchanged:

```ruby
project = Project.find(476); calculated = project.calculate_science_score_breakdown; puts "calculated_score: #{calculated[:score].inspect}"; pp calculated[:breakdown]; puts "stored_score: #{project.science_score.inspect}"; nil
```

Save a fresh score for the same project with the following block. `update_science_score` writes both the score and its breakdown:

```ruby
project = Project.find(476); project.update_science_score; puts "stored_score: #{project.reload.science_score.inspect}"; pp project.science_score_breakdown; nil
```

Two rake tasks support analysis. `science_score:compare` compares local calculations with a stratified sample from the production API. `science_score:joss_signals` compares signal prevalence in JOSS and non-JOSS samples.

```bash
bundle exec rake science_score:compare
SAMPLE=200 bundle exec rake science_score:joss_signals
```

Changes to weights or signal extraction should be checked against projects near 20 as well as the aggregate samples. Crossing 20 changes which downstream importers and classifiers include a project.
