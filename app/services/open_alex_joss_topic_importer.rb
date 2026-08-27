class OpenAlexJossTopicImporter
  BATCH_SIZE = 50
  SOURCE = "joss_doi"

  class << self
    def sync!(
      client: OpenAlexApiClient.new,
      scope: default_scope,
      batch_size: BATCH_SIZE,
      progress: nil
    )
      counts = {
        projects: scope.count,
        processed: 0,
        matched: 0,
        missing: 0,
        without_topics: 0,
        assignments: 0,
        unmatched_topics: 0,
      }

      scope.in_batches(of: batch_size) do |batch|
        sync_batch!(batch.pluck(:id, :joss_metadata), client, counts)
        progress&.call("OpenAlex JOSS projects processed: #{counts[:processed]}")
      end

      counts
    end

    def default_scope
      Project.visible.with_joss.where("joss_metadata ->> 'doi' IS NOT NULL")
    end

    def sync_batch!(projects, client, counts)
      project_ids_by_doi = projects.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(project_id, metadata), grouped|
        grouped[client.normalize_doi(metadata["doi"])] << project_id
      end
      works = client.works_by_dois(project_ids_by_doi.keys)
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

      project_ids_by_doi.each do |doi, project_ids|
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

          topics.each do |topic|
            local_id = local_topic_ids[topic["id"]]
            unless local_id
              counts[:unmatched_topics] += 1
              next
            end

            rows << {
              project_id: project_id,
              open_alex_topic_id: local_id,
              score: topic.fetch("score"),
              primary_topic: topic["id"] == primary_topic_id,
              source: SOURCE,
              source_identifier: doi,
              openalex_work_id: work.fetch("id"),
              created_at: now,
              updated_at: now,
            }
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
        ProjectOpenAlexTopic.where(
          project_id: matched_project_ids,
          source: SOURCE
        ).delete_all
        ProjectOpenAlexTopic.insert_all!(rows) if rows.any?
      end

      counts[:processed] += projects.length
      counts[:assignments] += rows.length
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
