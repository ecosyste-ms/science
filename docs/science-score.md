# Science Score

Science Score is a stored estimate of whether a repository contains research software. `ScienceScoreCalculator` returns a value from 0 to 100 with an evidence breakdown, and `Project#update_science_score` writes both values to `projects.science_score` and `projects.science_score_breakdown`.

`Project.scientific` starts at 20 and `Project.highly_scientific` starts at 75. Projects with any positive score appear in the general project browser and search. The 20-point threshold controls OpenAlex field classification, metadata repository discovery, institutional owner pages, and several import paths. Brief scanning accepts visible projects with a positive score because a Brief result can add evidence and raise the score.

## When scores change

A normal project sync fetches repository, package, dependency, commit, README, issue, citation, CodeMeta, and Zenodo data before calculating the score. A successful Brief scan also recalculates it because detected languages and tools can add research-tooling evidence.

Views and API responses read the saved breakdown. They do not calculate a new score during a request, so changed weights take effect only after the project is scored again.

## Non-JOSS projects

The standard path adds weighted signals. The table shows each signal's maximum point contribution. A fractional signal multiplies those points by its strength before the values are added.

```text
base score = sum(signal points * signal strength)
```

| Signal | Weight | Evidence |
| --- | ---: | --- |
| CITATION file | 16 | Stored citation file content |
| CodeMeta file | 13 | A CodeMeta filename reported by repository metadata |
| Zenodo file | 15 | A Zenodo filename reported by repository metadata |
| DOI reference | 13 | A DOI extracted from the README or JOSS metadata |
| Academic link | 8 | A recognized publication or archive host in the README |
| Academic committers | 5 | Fraction of committers matched to academic organization domains |
| Institutional owner | 10 | Organization owner matched to a research organization domain |
| Scientific registry | 7 | A package published through CRAN or Bioconductor |
| JOSS vocabulary | 13 | Vocabulary score of at least 30 from the active JOSS model |

The weights total 100 percent. CITATION evidence checks the downloaded file content, while CodeMeta and Zenodo evidence checks the filenames advertised by repository metadata. DOI details separate common archive prefixes, including Zenodo and Figshare, from journal references, but both count as the same scoring signal.

Academic committer strength is the sum of matched organization strengths divided by the number of committers. An institutional owner uses the matched domain strength directly. ROR company records can identify an institution for owner browsing, but company domains are excluded from academic email evidence.

The vocabulary signal is described in [JOSS vocabulary scoring](joss-vocabulary.md). Its raw score and matched terms remain in the saved breakdown even though the Science Score treats it as a present or absent 13-point signal.

## Brief and dependency bonuses

Research tooling can add up to 20 points after the weighted signals. Strong evidence includes research-domain tool taxonomy, Snakemake, Nextflow, nf-core, nf-test, MultiQC, Dockstore, or Fortran. DVC, ASV, and Fortitude receive strength 0.7. R and Julia evidence receives strength 0.4 for a qualifying tool or package-manager match and 0.7 for stronger combinations. Common research documentation tools and Python projects with at least three maturity categories receive strength 0.4.

A tooling strength above 0.4 applies on its own. Strength 0.4 applies only when the JOSS vocabulary signal is also present. The bonus is `20 * strength`.

Scientific package evidence can add 8 points. A project receives the bonus when its own package is on the scientific dependency list or at least three dependencies match that list. One or two matching dependencies remain in the breakdown with strengths 0.4 or 0.7 but do not add the bonus.

## Negative indicators

Repository topics and names can reduce the score after bonuses. Strong indicators such as `awesome`, `dotfiles`, homework, interview preparation, cheatsheets, and roadmaps apply an 80 percent penalty. Weak indicators such as tutorials, courses, templates, examples, demos, portfolios, and a fork with a recorded source apply a 50 percent penalty. A strong match takes precedence when both tiers occur.

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
