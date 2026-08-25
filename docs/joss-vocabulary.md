# JOSS vocabulary scoring

Projects accepted by the Journal of Open Source Software are a high-confidence sample of research software because acceptance includes editorial checks and peer review. Their READMEs contain domain terms, methods, scientific software names, and research context that can identify similar projects without a citation file, DOI, or academic-domain committer.

The vocabulary signal is intended to help with industry-lab software, sparse Fortran or C projects, and projects written in languages other than English. It uses only project text and does not depend on citation-graph data supplied by OpenAlex or papers.ecosyste.ms.

## Corpus inputs

The positive corpus contains projects with JOSS metadata. Each project contributes text from:

- its name
- its description, with the repository description as a fallback
- the first 5,000 characters of its README
- its project keywords

JOSS paper titles, tags, DOIs, and other paper metadata do not contribute vocabulary terms. The README and project description are the main source because they describe what the software does and the research problems it addresses.

The comparison corpus contains non-JOSS projects with READMEs. Projects that explicitly reference JOSS are left out of this corpus because many are research projects whose JOSS metadata has not been associated with the project record. Comparison rates are matched to the JOSS README length distribution using five length bands.

## README sections

README text is parsed as Markdown before tokenization. ATX headings, setext headings, and HTML headings are recognized, and heading text never contributes terms.

The body of a research section such as `Statement of Need`, `Overview`, `Introduction`, `Usage`, or `Examples` remains in the corpus. Administrative and template sections are skipped when their headings identify installation, contribution, documentation, citation, license, references, acknowledgements, or community guidelines.

The parser also removes:

- fenced and indented code
- badges, images, HTML tags, and URLs
- BibTeX entries and explicit JOSS citations
- invalid UTF-8 bytes
- the template phrases `Statement of Need` and `Community Guidelines` when they appear in a table of contents or prose reference

## Terms and weights

Tokenization produces Unicode words and adjacent two-word terms. A token must start with a letter and contain between 3 and 40 letters or digits. Standalone numbers such as `21105` are discarded, while mixed identifiers such as `mpi4py` and `hdf5` remain.

Document frequency counts each term at most once per project. A candidate must appear in at least 10 JOSS projects, be at least twice as common in the length-matched JOSS corpus, and meet a 1.5-times enrichment check in at least three of four project folds.

Each retained term receives this weight:

```text
min(log(enrichment) * joss_count / (joss_count + 10), 3)
```

The completed model is inserted into `joss_vocabulary_models`. Its JSON fields contain term weights, build configuration, source counts, and diagnostics for the 50 highest-weighted terms. A build writes its row only after every source project has been processed, so an interrupted build leaves the previous model active.

## Project scoring

Scoring loads the newest model and matches its terms against the target project's name, description, README, and keywords. Terms that share a word are grouped before evidence is added, which prevents a phrase such as `open source Python package for` from contributing `source_python`, `python_package`, and `package_for` as three separate signals.

The strongest term from each group is retained, and the three strongest groups contribute to the score:

```text
score = min(evidence / 3 * 30, 100)
```

`ScienceScoreCalculator` treats a vocabulary score of 30 or higher as present for non-JOSS projects. The breakdown records the score, matched terms, and model ID. JOSS projects already receive their peer-reviewed base score, so this extra check is skipped for them.

## Worker cache

Each worker parses the newest database model once and keeps it in memory for one day. Model generations change weekly, so checking the database on every project would add work without improving the score.

An empty model result is cached for five minutes. This shorter interval lets workers recover soon after the first model is built following a new deployment.

## Rebuilding the model

Create the table and seed the first model after deployment:

```bash
bundle exec rails db:migrate
bundle exec rake joss_vocabulary:rebuild
```

Inspect the active model with:

```bash
bundle exec rake joss_vocabulary:stats
```

`app.json` schedules `joss_vocabulary:rebuild` for 03:00 every Sunday. The task streams projects in batches and keeps document-frequency maps in memory. It does not write a README corpus or a container-local cache to disk.

## Interpreting validation data

JOSS membership is a positive label, while the non-JOSS comparison corpus is unlabeled. A match in the comparison corpus may be a desired discovery, especially for research code that lacks publication metadata. Inspect projects around the score threshold as well as aggregate match rates when changing tokenization, weighting, or section rules.
