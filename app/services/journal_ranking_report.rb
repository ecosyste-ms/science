class JournalRankingReport
  def call(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
    projects = Project.visible.select(:id).to_sql
    packages = Package.visible.select(:id).to_sql
    sql = <<~SQL
      WITH raw_links AS (
        SELECT paper_id, 'project' AS kind, project_id AS entity_id,
          role = 'software_description' OR evidence @> '[{"relationship":"software_description"}]'::jsonb AS described,
          role = 'implementation' AS implemented, false AS model, role = 'reference' AS referenced
        FROM project_papers WHERE project_id IN (#{projects})
        UNION ALL
        SELECT paper_id, 'package', package_id, false, false,
          role IN ('model_paper', 'model_family_paper'), role = 'reference'
        FROM package_papers WHERE package_id IN (#{packages})
        UNION ALL
        SELECT paper_id, 'project', project_id,
          EXISTS (SELECT 1 FROM mention_sources WHERE mention_id = mentions.id AND lower(source) = 'joss'),
          false, false, true
        FROM mentions WHERE project_id IN (#{projects}) AND paper_id IS NOT NULL
      ), links AS (
        SELECT paper_id, kind, entity_id, bool_or(described) AS described,
          bool_or(implemented) AS implemented, bool_or(model) AS model, bool_or(referenced) AS referenced
        FROM raw_links GROUP BY paper_id, kind, entity_id
      ), paper_sources AS MATERIALIZED (
        SELECT id, openalex_id, openalex_data->'primary_location'->'source' AS source
        FROM papers WHERE id IN (SELECT paper_id FROM links)
      ), identifiers AS (
        SELECT id, openalex_id, source->>'display_name' AS name, nullif(lower(btrim(source->>'type')), '') AS source_type,
          CASE WHEN lower(source->>'id') ~ '^(https?://openalex[.]org/)?s[0-9]+$'
            THEN 'https://openalex.org/' || upper(regexp_replace(lower(source->>'id'), '^https?://openalex[.]org/', '')) END AS source_id,
          CASE WHEN upper(source->>'issn_l') ~ '^[0-9]{4}-[0-9]{3}[0-9X]$' THEN upper(source->>'issn_l')
            WHEN upper(source->'issn'->>0) ~ '^[0-9]{4}-[0-9]{3}[0-9X]$' THEN upper(source->'issn'->>0) END AS issn
        FROM paper_sources
      ), issn_sources AS (
        SELECT issn, min(source_id) AS source_id FROM identifiers
        WHERE issn IS NOT NULL AND source_id IS NOT NULL
        GROUP BY issn HAVING count(DISTINCT source_id) = 1
      ), associations AS (
        SELECT links.*, identifiers.openalex_id, identifiers.name, identifiers.source_type, identifiers.issn,
          coalesce(identifiers.source_id, issn_sources.source_id) AS source_id,
          coalesce(identifiers.source_id, issn_sources.source_id, 'issn:' || identifiers.issn) AS source_key
        FROM links JOIN identifiers ON identifiers.id = links.paper_id
        LEFT JOIN issn_sources ON issn_sources.issn = identifiers.issn
      ), sources AS (
        SELECT source_key, max(source_id) AS source_id, max(name) AS name, max(issn) AS issn,
          CASE WHEN count(DISTINCT source_type) = 1 THEN max(source_type) ELSE 'unknown' END AS source_type,
          count(DISTINCT paper_id) AS papers,
          count(DISTINCT entity_id) FILTER (WHERE kind = 'project') AS projects,
          count(DISTINCT entity_id) FILTER (WHERE kind = 'package') AS packages,
          count(*) AS software_paper_pairs,
          count(*) FILTER (WHERE described OR implemented OR model) AS direct_pairs,
          count(*) FILTER (WHERE referenced AND NOT (described OR implemented OR model)) AS reference_only_pairs,
          count(*) FILTER (WHERE described) AS software_description_pairs,
          count(*) FILTER (WHERE implemented) AS implementation_pairs,
          count(*) FILTER (WHERE model) AS model_pairs
        FROM associations WHERE source_key IS NOT NULL GROUP BY source_key
      )
      SELECT jsonb_build_object(
        'summary', (SELECT jsonb_build_object(
          'linked_papers', count(DISTINCT paper_id), 'software_paper_pairs', count(*),
          'projects', count(DISTINCT entity_id) FILTER (WHERE kind = 'project'),
          'packages', count(DISTINCT entity_id) FILTER (WHERE kind = 'package'),
          'missing_source_papers', count(DISTINCT paper_id) FILTER (WHERE source_key IS NULL),
          'papers_without_openalex_id', count(DISTINCT paper_id) FILTER (WHERE nullif(btrim(openalex_id), '') IS NULL),
          'sources', count(DISTINCT source_key)) FROM associations),
        'sources', coalesce((SELECT jsonb_agg(ranked) FROM (
          SELECT * FROM sources ORDER BY direct_pairs DESC, papers DESC, source_key LIMIT #{limit}
        ) ranked), '[]'::jsonb)
      ) AS report
    SQL
    value = ApplicationRecord.connection.select_value(sql)
    report = value.is_a?(String) ? JSON.parse(value) : value
    sources = report.delete("sources")
    report.merge("journals" => sources.select { |source| source["source_type"] == "journal" },
      "other_sources" => sources.reject { |source| %w[journal unknown].include?(source["source_type"]) },
      "unknown_sources" => sources.select { |source| source["source_type"] == "unknown" },
      "truncated" => report.fetch("summary").fetch("sources") > limit,
      "scope" => "visible projects and packages with normalized paper associations")
  end
end
