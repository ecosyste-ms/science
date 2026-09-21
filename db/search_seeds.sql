PRAGMA foreign_keys = ON;
PRAGMA user_version = 1;

CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE projects (
  project_id INTEGER PRIMARY KEY,
  repository_url TEXT NOT NULL,
  science_score REAL NOT NULL,
  updated_at TEXT NOT NULL,
  last_synced_at TEXT
);

CREATE TABLE packages (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(project_id),
  package_id INTEGER,
  purl TEXT,
  registry TEXT,
  ecosystem TEXT
);

CREATE TABLE seeds (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(project_id),
  package_entry_id INTEGER REFERENCES packages(id),
  type TEXT NOT NULL,
  value TEXT NOT NULL,
  normalized_value TEXT NOT NULL,
  source TEXT NOT NULL,
  relation TEXT NOT NULL
);

CREATE TABLE project_fields (
  project_id INTEGER NOT NULL REFERENCES projects(project_id),
  openalex_id TEXT NOT NULL,
  name TEXT NOT NULL,
  domain TEXT NOT NULL,
  confidence_score REAL NOT NULL,
  PRIMARY KEY (project_id, openalex_id)
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
