# [Ecosyste.ms: Science](https://science.ecosyste.ms)

A discovery and classification system for open source scientific software projects. This platform helps researchers, developers, and institutions find, evaluate, and connect with scientific computing tools, research software, and data analysis libraries across all domains of science.

## About

Scientific software is the foundation of modern research, yet it remains difficult to discover and evaluate. Researchers often struggle to find existing tools for their domain, assess software quality and scientific rigor, or identify opportunities for collaboration. Research software is frequently developed in academic silos, leading to duplicated effort and missed connections between related projects.

Ecosyste.ms: Science addresses these challenges by:

- **Aggregating** scientific software from multiple sources (GitHub, package registries, academic journals)
- **Analyzing** projects using a multi-dimensional science score that evaluates citations, academic affiliations, peer review status, and scientific vocabulary
- **Classifying** projects into scientific fields and domains to improve discoverability
- **Connecting** researchers with related projects, potential collaborators, and research infrastructure
- **Tracking** institutional contributions by identifying academic and research organization affiliations from contributor email domains

The platform makes research software more visible, helping researchers discover tools, institutions recognize their software impact, and funders identify critical research infrastructure that needs support.

This project is part of [Ecosyste.ms](https://ecosyste.ms): Tools and open datasets to support, sustain, and secure critical digital infrastructure.

## Features

### Scientific Software Discovery
- **Automated Discovery**: Continuously discovers scientific software from GitHub, GitLab, and other sources
- **Multi-Source Integration**: Aggregates data from repositories, package registries, and academic databases
- **JOSS Integration**: Includes all papers from the Journal of Open Source Software
- **Topic-Based Search**: Find projects by scientific domain, keywords, or research areas

### Project Classification & Analysis
- **Field Classification**: Automatically categorizes projects into 17 scientific fields across 4 domains:
  - Physical Sciences (Physics, Chemistry, Materials Science, Earth Sciences, Astronomy)
  - Life Sciences (Biology, Medicine, Neuroscience, Biochemistry, Genetics)
  - Social Sciences (Economics, Psychology, Sociology)
  - Computer Science (Artificial Intelligence, Computational Biology, Data Science, Scientific Computing)
- **Science Score**: Evaluates scientific merit (0-100) based on:
  - Presence of citation files (CITATION.cff)
  - Published JOSS papers
  - DOI references and academic links
  - Academic contributor affiliations
  - Scientific vocabulary analysis
- **Quality Metrics**: Tracks maintenance, activity, dependencies, and community engagement

### Advanced Analytics
- **JOSS Vocabulary Analysis**: Uses TF-IDF to compare projects against the corpus of peer-reviewed scientific software
- **Contributor Networks**: Maps academic institutions and research collaborations through email domain analysis
- **Institutional Tracking**: Identifies and tracks contributions from universities, research labs, and academic organizations
- **Dependency Mapping**: Visualizes how scientific packages interconnect
- **Citation Tracking**: Monitors academic citations and research impact via DOI references

## Current Scale

- **60,000+** scientific software projects tracked
- **2,800+** peer-reviewed JOSS papers included
- **48,000+** projects with calculated science scores
- **17** scientific fields for classification
- **100+** academic institutions recognized

## Use Cases

- **Researchers**: Find specialized tools for your scientific domain
- **Developers**: Discover similar projects and potential collaborations
- **Institutions**: Track your organization's scientific software contributions
- **Funders**: Identify critical research infrastructure needing support
- **Students**: Explore real-world scientific computing implementations

## API

Documentation for the REST API is available here: [https://science.ecosyste.ms/docs](https://science.ecosyste.ms/docs)

The default rate limit for the API is 5000/req per hour based on your IP address, get in contact if you need to to increase your rate limit.

## Development

For development and deployment documentation, check out [DEVELOPMENT.md](DEVELOPMENT.md)

## Contribute

Please do! The source code is hosted at [GitHub](https://github.com/ecosyste-ms/science). If you want something, [open an issue](https://github.com/ecosyste-ms/science/issues/new) or a pull request.

If you need want to contribute but don't know where to start, take a look at the issues tagged as ["Help Wanted"](https://github.com/ecosyste-ms/science/issues?q=is%3Aopen+is%3Aissue+label%3A%22help+wanted%22).

You can also help triage issues. This can include reproducing bug reports, or asking for vital information such as version numbers or reproduction instructions.

Finally, this is an open source project. If you would like to become a maintainer, we will consider adding you if you contribute frequently to the project. Feel free to ask.

For other updates, follow the project on Twitter: [@ecosyste_ms](https://twitter.com/ecosyste_ms).

### Note on Patches/Pull Requests

* Fork the project.
* Make your feature addition or bug fix.
* Add tests for it. This is important so we don't break it in a future version unintentionally.
* Send a pull request. Bonus points for topic branches.

### Vulnerability disclosure

We support and encourage security research on Ecosyste.ms under the terms of our [vulnerability disclosure policy](https://github.com/ecosyste-ms/science/security/policy).

### Code of Conduct

Please note that this project is released with a [Contributor Code of Conduct](https://github.com/ecosyste-ms/.github/blob/main/CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

## Copyright

Code is licensed under [GNU Affero License](LICENSE) © 2023 [Andrew Nesbitt](https://github.com/andrew).

Data from the API is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
