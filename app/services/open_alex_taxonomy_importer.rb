class OpenAlexTaxonomyImporter
  MINIMUM_TOPICS = 4_000
  UPSERT_BATCH_SIZE = 500

  class << self
    def sync!(
      client: OpenAlexApiClient.new,
      minimum_topics: MINIMUM_TOPICS,
      progress: nil
    )
      topics = []
      pages = 0

      client.each_topic_page do |page|
        topics.concat(page)
        pages += 1
        progress&.call("OpenAlex topics fetched: #{topics.length}")
      end

      topics = topics.index_by { |topic| topic.fetch("id") }.values
      if topics.length < minimum_topics
        raise "OpenAlex returned #{topics.length} topics; expected at least #{minimum_topics}"
      end

      import!(topics, pages: pages)
    end

    def import!(topics, pages: 1)
      now = Time.current
      rows = topics.map { |topic| attributes_for(topic, now) }
      ids = rows.pluck(:openalex_id)
      existing = OpenAlexTopic.where(openalex_id: ids).count
      deactivated = 0

      OpenAlexTopic.transaction do
        rows.each_slice(UPSERT_BATCH_SIZE) do |batch|
          OpenAlexTopic.upsert_all(
            batch,
            unique_by: :openalex_id,
            update_only: update_columns
          )
        end
        deactivated = OpenAlexTopic.where.not(openalex_id: ids)
          .update_all(active: false, updated_at: now)
      end

      {
        topics: rows.length,
        pages: pages,
        created: rows.length - existing,
        refreshed: existing,
        deactivated: deactivated,
      }
    end

    def attributes_for(topic, now)
      {
        openalex_id: topic.fetch("id"),
        display_name: topic.fetch("display_name"),
        description: topic["description"],
        keywords: normalize_keywords(topic["keywords"]),
        subfield_id: topic.dig("subfield", "id").to_s,
        subfield_name: topic.dig("subfield", "display_name"),
        field_id: topic.dig("field", "id").to_s,
        field_name: topic.dig("field", "display_name"),
        domain_id: topic.dig("domain", "id").to_s,
        domain_name: topic.dig("domain", "display_name"),
        source_updated_at: topic["updated_date"],
        active: true,
        created_at: now,
        updated_at: now,
      }
    end

    def normalize_keywords(keywords)
      Array(keywords).filter_map do |keyword|
        keyword.is_a?(Hash) ? keyword["display_name"] : keyword.to_s.presence
      end
    end

    def update_columns
      %i[
        display_name description keywords subfield_id subfield_name
        field_id field_name domain_id domain_name source_updated_at active
      ]
    end
  end
end
