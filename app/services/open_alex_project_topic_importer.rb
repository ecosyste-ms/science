class OpenAlexProjectTopicImporter
  BATCH_SIZE = 50
  MAX_README_IDENTIFIERS = 10
  JOSS_SOURCE = "joss_doi"
  README_DOI_SOURCE = "readme_doi"
  README_ARXIV_SOURCE = "readme_arxiv"
  METADATA_DOI_SOURCE = "metadata_doi"
  METADATA_ASSIGNMENT_SOURCE_PREFIXES = %w[
    citation_bib.
    citation_cff.
    codemeta.
    zenodo.
  ].freeze

  class << self
    def sync!(
      source:,
      client: OpenAlexApiClient.new,
      scope: nil,
      batch_size: BATCH_SIZE,
      progress: nil
    )
      scope ||= default_scope(source)
      counts = {
        projects: scope.count,
        processed: 0,
        dois: 0,
        matched: 0,
        missing: 0,
        without_topics: 0,
        assignments: 0,
        unmatched_topics: 0,
        skipped_many_identifiers: 0,
      }

      scope.in_batches(of: batch_size) do |batch|
        projects = batch.select(*project_columns(source)).to_a
        sync_batch!(projects, client, counts, source)
        progress&.call("OpenAlex #{source.tr('_', ' ')} projects processed: #{counts[:processed]}")
      end

      counts
    end

    def default_scope(source)
      case source
      when JOSS_SOURCE
        Project.visible.with_joss.where("joss_metadata ->> 'doi' IS NOT NULL")
      when README_DOI_SOURCE
        Project.visible.scientific.with_readme.where(
          "readme ~* ?",
          "10\\.[0-9]{4,9}(/|%2f)"
        )
      when README_ARXIV_SOURCE
        Project.visible.scientific.with_readme.where(
          "readme ~* ?",
          "arxiv:|arxiv\\.org/(abs|pdf)/"
        )
      when METADATA_DOI_SOURCE
        Project.visible.scientific.where(
          "NULLIF(citation_file, '') IS NOT NULL OR " \
          "NULLIF(codemeta, '') IS NOT NULL OR " \
          "NULLIF(zenodo, '') IS NOT NULL"
        )
      else
        raise ArgumentError, "Unknown OpenAlex topic source: #{source}"
      end
    end

    def sync_batch!(projects, client, counts, source)
      references_by_doi = Hash.new { |hash, key| hash[key] = [] }
      skipped_project_ids = []
      projects.each do |project|
        if too_many_readme_identifiers?(project, source)
          skipped_project_ids << project.id
          counts[:skipped_many_identifiers] += 1
          next
        end

        doi_candidates_for(project, source).each do |candidate|
          doi = client.normalize_doi(candidate[:value])
          next unless doi.present?

          references_by_doi[doi] << {
            project_id: project.id,
            source: candidate[:source],
            source_identifier: candidate[:source_identifier] || doi,
          }
        end
      end
      references_by_doi.each_value(&:uniq!)
      counts[:dois] += references_by_doi.sum do |_, references|
        references.map { |reference| reference[:project_id] }.uniq.length
      end

      works = if references_by_doi.any?
        client.works_by_dois(references_by_doi.keys)
      else
        []
      end
      work_by_doi = works.index_by { |work| client.normalize_doi(work["doi"]) }
      topic_ids = works.flat_map { |work| work_topics(work) }
        .filter_map { |topic| topic["id"] }
        .uniq
      local_topic_ids = OpenAlexTopic.where(openalex_id: topic_ids)
        .pluck(:openalex_id, :id)
        .to_h
      now = Time.current
      rows = []
      matched_project_ids = []

      references_by_doi.each do |doi, references|
        project_ids = references.map { |reference| reference[:project_id] }.uniq
        work = work_by_doi[doi]
        unless work
          counts[:missing] += project_ids.length
          next
        end

        primary_topic_id = work.dig("primary_topic", "id")
        topics = work_topics(work)
        counts[:without_topics] += project_ids.length if topics.empty?
        project_ids.each do |project_id|
          matched_project_ids << project_id
          counts[:matched] += 1
          assignment_references = references
            .select { |reference| reference[:project_id] == project_id }
            .uniq { |reference| [reference[:source], reference[:source_identifier]] }

          topics.each do |topic|
            local_id = local_topic_ids[topic["id"]]
            unless local_id
              counts[:unmatched_topics] += 1
              next
            end

            assignment_references.each do |reference|
              rows << {
                project_id: project_id,
                open_alex_topic_id: local_id,
                score: topic.fetch("score"),
                primary_topic: topic["id"] == primary_topic_id,
                source: reference[:source],
                source_identifier: reference[:source_identifier],
                openalex_work_id: work.fetch("id"),
                created_at: now,
                updated_at: now,
              }
            end
          end
        end
      end

      rows.uniq! do |row|
        [
          row[:project_id], row[:open_alex_topic_id],
          row[:source], row[:source_identifier],
        ]
      end

      ProjectOpenAlexTopic.transaction do
        delete_current_assignments(
          (matched_project_ids + skipped_project_ids).uniq,
          source
        )
        ProjectOpenAlexTopic.insert_all!(rows) if rows.any?
      end

      counts[:processed] += projects.length
      counts[:assignments] += rows.length
    end

    def doi_candidates_for(project, source)
      case source
      when JOSS_SOURCE
        [project.joss_metadata&.[]("doi")].compact.map do |value|
          { value: value, source: JOSS_SOURCE }
        end
      when README_DOI_SOURCE
        project.dois.map { |value| { value: value, source: README_DOI_SOURCE } }
      when README_ARXIV_SOURCE
        project.arxiv_ids.map do |identifier|
          {
            value: Project.arxiv_doi(identifier),
            source: README_ARXIV_SOURCE,
            source_identifier: identifier,
          }
        end
      when METADATA_DOI_SOURCE
        project.open_alex_metadata_doi_candidates
      else
        raise ArgumentError, "Unknown OpenAlex topic source: #{source}"
      end
    end

    def project_columns(source)
      case source
      when JOSS_SOURCE
        %i[id joss_metadata]
      when README_DOI_SOURCE, README_ARXIV_SOURCE
        %i[id readme]
      when METADATA_DOI_SOURCE
        %i[id url citation_file codemeta zenodo]
      else
        raise ArgumentError, "Unknown OpenAlex topic source: #{source}"
      end
    end

    def too_many_readme_identifiers?(project, source)
      return false unless [README_DOI_SOURCE, README_ARXIV_SOURCE].include?(source)

      project.open_alex_readme_dois.length > MAX_README_IDENTIFIERS
    end

    def delete_current_assignments(project_ids, source)
      assignments = ProjectOpenAlexTopic.where(project_id: project_ids)
      if source == METADATA_DOI_SOURCE
        clauses = METADATA_ASSIGNMENT_SOURCE_PREFIXES.map { "source LIKE ?" }.join(" OR ")
        patterns = METADATA_ASSIGNMENT_SOURCE_PREFIXES.map { |prefix| "#{prefix}%" }
        assignments.where(clauses, *patterns).delete_all
      else
        assignments.where(source: source).delete_all
      end
    end

    def work_topics(work)
      topics = Array(work["topics"])
      topics = [work["primary_topic"]].compact if topics.empty?
      topics.select do |topic|
        topic["id"].present? && topic["score"].to_f.between?(0, 1)
      end
    end
  end
end
