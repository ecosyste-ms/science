PRAGMA foreign_keys = ON;
PRAGMA user_version = 2;

CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE projects (
  project_id INTEGER PRIMARY KEY,
  repository_url TEXT NOT NULL,
  science_score REAL NOT NULL,
  updated_at TEXT NOT NULL,
  last_synced_at TEXT,
  search_year TEXT NOT NULL CHECK (json_valid(search_year)),
  suggested_start_year INTEGER
);

CREATE TABLE packages (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(project_id),
  package_id INTEGER,
  purl TEXT,
  registry TEXT,
  ecosystem TEXT,
  search_year TEXT NOT NULL CHECK (json_valid(search_year)),
  suggested_start_year INTEGER
);

CREATE TABLE project_contexts (
  project_id INTEGER PRIMARY KEY REFERENCES projects(project_id),
  data TEXT NOT NULL CHECK (json_valid(data))
);

CREATE TABLE seeds (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(project_id),
  package_entry_id INTEGER REFERENCES packages(id),
  type TEXT NOT NULL,
  value TEXT NOT NULL,
  normalized_value TEXT NOT NULL,
  source TEXT NOT NULL,
  relation TEXT NOT NULL,
  identifier_evidence TEXT CHECK (identifier_evidence IS NULL OR json_valid(identifier_evidence)),
  name_evidence TEXT CHECK (name_evidence IS NULL OR json_valid(name_evidence))
);

CREATE TABLE project_fields (
  project_id INTEGER NOT NULL REFERENCES projects(project_id),
  openalex_id TEXT NOT NULL,
  name TEXT NOT NULL,
  domain TEXT NOT NULL,
  confidence_score REAL NOT NULL,
  PRIMARY KEY (project_id, openalex_id)
);

CREATE TABLE clues (
  id INTEGER PRIMARY KEY,
  value TEXT NOT NULL,
  case_sensitive INTEGER NOT NULL CHECK (case_sensitive IN (0, 1)),
  shared_name INTEGER NOT NULL DEFAULT 0 CHECK (shared_name IN (0, 1)),
  ordinary_word INTEGER CHECK (ordinary_word IN (0, 1)),
  short_name INTEGER NOT NULL DEFAULT 0 CHECK (short_name IN (0, 1)),
  punctuation_only INTEGER NOT NULL DEFAULT 0 CHECK (punctuation_only IN (0, 1)),
  non_specific_url INTEGER NOT NULL DEFAULT 0 CHECK (non_specific_url IN (0, 1)),
  generic_name INTEGER NOT NULL DEFAULT 0 CHECK (generic_name IN (0, 1)),
  word_evidence TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(word_evidence)),
  ambiguous INTEGER NOT NULL DEFAULT 0 CHECK (ambiguous IN (0, 1)),
  suggested_start_year INTEGER,
  UNIQUE (value, case_sensitive)
);

CREATE TABLE clue_seeds (
  clue_id INTEGER NOT NULL REFERENCES clues(id),
  seed_id INTEGER NOT NULL REFERENCES seeds(id),
  variant TEXT NOT NULL,
  PRIMARY KEY (clue_id, seed_id, variant)
);

CREATE INDEX projects_repository_url ON projects(repository_url);
CREATE INDEX packages_project_id ON packages(project_id);
CREATE INDEX packages_package_id ON packages(package_id);
CREATE INDEX packages_purl ON packages(purl);
CREATE INDEX packages_registry ON packages(registry COLLATE NOCASE);
CREATE INDEX seeds_lookup ON seeds(type, normalized_value);
CREATE INDEX seeds_project_id ON seeds(project_id);
CREATE INDEX seeds_package_entry_id ON seeds(package_entry_id);
CREATE INDEX project_fields_openalex_id ON project_fields(openalex_id);
CREATE INDEX clue_seeds_seed_id ON clue_seeds(seed_id);
CREATE INDEX clues_ambiguous ON clues(ambiguous);

CREATE VIEW clue_candidates AS
SELECT DISTINCT cs.clue_id, s.project_id, s.package_entry_id, k.package_id, k.purl,
       CASE WHEN s.package_entry_id IS NULL THEN p.suggested_start_year ELSE k.suggested_start_year END AS suggested_start_year,
       CASE WHEN s.package_entry_id IS NULL THEN p.search_year ELSE k.search_year END AS search_year
FROM clue_seeds cs
JOIN seeds s ON s.id = cs.seed_id
JOIN projects p ON p.project_id = s.project_id
LEFT JOIN packages k ON k.id = s.package_entry_id;

CREATE VIEW clue_candidate_details AS
SELECT c.*, p.repository_url,
       CASE WHEN json_type(ctx.data, '$.repository_provenance.fork.value') IN ('true', 'false')
            THEN json_extract(ctx.data, '$.repository_provenance.fork.value') END AS fork,
       json_extract(ctx.data, '$.repository_provenance.source_name.value') AS fork_source_name,
       json_extract(ctx.data, '$.repository_provenance.mirror_url.value') AS mirror_url
FROM clue_candidates c
JOIN projects p ON p.project_id = c.project_id
LEFT JOIN project_contexts ctx ON ctx.project_id = c.project_id;

CREATE VIEW clue_candidate_summary AS
SELECT clue_id, COUNT(DISTINCT project_id) AS project_candidates,
       COUNT(DISTINCT package_entry_id) AS package_candidates,
       COUNT(DISTINCT CASE WHEN fork = 1 THEN project_id END) AS fork_projects,
       COUNT(DISTINCT CASE WHEN fork = 0 THEN project_id END) AS nonfork_projects,
       COUNT(DISTINCT CASE WHEN fork IS NULL THEN project_id END) AS unknown_fork_projects,
       'exported_projects' AS count_scope
FROM clue_candidate_details
GROUP BY clue_id;

CREATE VIEW registry_coverage AS
SELECT registry COLLATE NOCASE AS registry, ecosystem COLLATE NOCASE AS ecosystem,
       COUNT(*) AS package_entries, COUNT(DISTINCT project_id) AS projects,
       SUM(package_id IS NULL) AS entries_without_package_id,
       SUM(purl IS NULL) AS entries_without_purl
FROM packages
GROUP BY registry COLLATE NOCASE, ecosystem COLLATE NOCASE;

CREATE VIEW field_coverage AS
SELECT openalex_id, name, domain, COUNT(*) AS projects
FROM project_fields
GROUP BY openalex_id, name, domain;

CREATE VIEW name_collisions AS
SELECT normalized_value, COUNT(DISTINCT project_id) AS projects,
       COUNT(DISTINCT package_entry_id) AS package_entries
FROM seeds
WHERE type = 'name'
GROUP BY normalized_value
HAVING COUNT(DISTINCT project_id) > 1 OR COUNT(DISTINCT package_entry_id) > 1;
