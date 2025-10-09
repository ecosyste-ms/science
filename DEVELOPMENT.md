# Development

## Setup

First things first, you'll need to fork and clone the project to your local machine.

`git clone https://github.com/ecosyste-ms/science.git`

The project uses ruby on rails which have a number of system dependencies you'll need to install. 

- [ruby](https://www.ruby-lang.org/en/documentation/installation/)
- [postgresql 14](https://www.postgresql.org/download/)
- [redis 6+](https://redis.io/download/)
- [node.js 16+](https://nodejs.org/en/download/)

Once you've got all of those installed, from the root directory of the project run the following commands:

```
bundle install
bundle exec rake db:create
bundle exec rake db:migrate
rails server
```

You can then load up [http://localhost:3000](http://localhost:3000) to access the service.

### Docker

Alternatively you can use the existing docker configuration files to run the app in a container.

Run this command from the root directory of the project to start the service.

`docker-compose up --build`

You can then load up [http://localhost:3000](http://localhost:3000) to access the service.

For access the rails console use the following command:

`docker-compose exec app rails console`

Runing rake tasks in docker follows a similar pattern:

`docker-compose exec app rake projects:sync`

## Importing data

The default set of supported data sources are listed in [db/seeds.rb](db/seeds.rb) and can be automatically enabled with the following rake command:

`rake db:seed`

You can then start syncing data for each source with the following command, this may take a while:

`rake projects:sync`

## Tests

The applications tests can be found in [test](test) and use the testing framework [minitest](https://github.com/minitest/minitest).

You can run all the tests with:

`rails test`

## Rake tasks

The applications rake tasks can be found in [lib/tasks](lib/tasks).

You can list all of the available rake tasks with the following command:

`rake -T`

### Data Import & Management Tasks

The platform includes several rake tasks for importing and managing scientific software data from various sources.

#### Core Import Tasks

**JOSS & Academic Papers:**
```bash
rake projects:import_joss                    # Import all JOSS papers and their software repositories
rake projects:import_papers                  # Import from papers.ecosyste.ms (academic citations)
rake projects:import_all_joss_topics         # Import top 50 topics from JOSS papers (GitHub topics)
rake projects:import_all_joss_keywords       # Import top 50 keywords from JOSS papers (package keywords)
```

**Package Registries:**
```bash
rake projects:import_cran                    # Import R packages from CRAN with GitHub repos
rake projects:import_bioconductor            # Import bioinformatics packages from Bioconductor
rake projects:import_conda_forge             # Import conda-forge packages with GitHub repos
```

**GitHub Discovery:**
```bash
rake projects:import_github_topic[topic]     # Import projects by GitHub topic (e.g., science, astronomy)
rake projects:import_github_owner[owner]     # Import all repositories from a GitHub owner/org
rake projects:import_all_github_owners       # Import from all known scientific GitHub owners (min_score=50)
rake projects:import_package_keyword[keyword] # Import packages by keyword
```

**Other Sources:**
```bash
rake projects:import_ost                     # Import from Open Sustainable Technology
rake projects:discover                       # Auto-discover via topics and keywords
```

#### Project Management

```bash
rake projects:sync                           # Sync least recently synced projects (500 at a time)
rake projects:sync_reviewed                  # Sync reviewed projects
rake projects:sync_dependencies              # Update dependency information across projects
```

#### JOSS Vocabulary Analysis

The platform uses TF-IDF analysis to compare projects against the corpus of peer-reviewed JOSS papers to calculate scientific vocabulary similarity:

```bash
rake joss_idf:build_cache                    # Build IDF corpus cache from JOSS papers (required first)
rake joss_idf:stats                          # Show cache statistics and top scientific terms
rake joss_idf:test                           # Test similarity scoring on sample projects
rake joss_idf:clear_cache                    # Clear the corpus cache
```

**Note:** Run `rake joss_idf:build_cache` before calculating science scores for the first time. This builds a TF-IDF model from all JOSS papers to identify scientific vocabulary.

#### Example Import Workflow

```bash
# 1. Build the JOSS vocabulary corpus (one-time setup)
rake joss_idf:build_cache

# 2. Import core scientific software
rake projects:import_joss
rake projects:import_papers
rake projects:import_all_joss_topics

# 3. Import from package registries
rake projects:import_cran
rake projects:import_bioconductor
rake projects:import_conda_forge

# 4. Sync and analyze imported projects
rake projects:sync

# 5. Check JOSS vocabulary analysis statistics
rake joss_idf:stats
```

## Deployment

A container-based deployment is highly recommended, we use [dokku.com](https://dokku.com/).