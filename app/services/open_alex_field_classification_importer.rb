class OpenAlexFieldClassificationImporter
  BATCH_SIZE = 500

  attr_reader :classifier, :scope, :limit, :progress

  def self.sync!(scope: nil, limit: nil, classifier: nil, progress: nil)
    new(
      scope: scope,
      limit: limit,
      classifier: classifier,
      progress: progress
    ).sync!
  end

  def initialize(scope: nil, limit: nil, classifier: nil, progress: nil)
    @scope = scope || Project.visible.scientific
    @limit = limit.to_i if limit.to_i.positive?
    @classifier = classifier || OpenAlexTopicClassifier.new
    @progress = progress
  end

  def sync!
    fields = sync_fields!
    counts = {
      fields: fields.length,
      projects: 0,
      classified_projects: 0,
      classifications: 0,
    }

    project_scope.find_in_batches(batch_size: BATCH_SIZE) do |projects|
      rows = classification_rows(projects, fields)
      project_ids = projects.map(&:id)

      ProjectField.transaction do
        ProjectField.where(project_id: project_ids, field_id: fields.values).delete_all
        ProjectField.insert_all!(rows) if rows.any?
      end

      counts[:projects] += projects.length
      counts[:classified_projects] += rows.map { |row| row[:project_id] }.uniq.length
      counts[:classifications] += rows.length
      progress&.call("OpenAlex field projects classified: #{counts[:projects]}")
    end

    counts
  end

  def sync_fields!
    now = Time.current
    upgraded_field_ids = []
    rows = OpenAlexTopic.active
      .pluck(:field_id, :field_name, :domain_name)
      .uniq
      .sort_by { |field_id, field_name, _| [field_id, field_name] }
    active_ids = rows.map(&:first)

    Field.open_alex.where.not(openalex_id: active_ids)
      .update_all(openalex_id: nil, updated_at: now)

    rows.to_h do |openalex_id, name, domain|
      field = Field.find_by(openalex_id: openalex_id) ||
        Field.find_or_initialize_by(name: name)
      upgrading_legacy_field = field.persisted? && field.openalex_id.nil?
      field.assign_attributes(
        openalex_id: openalex_id,
        name: name,
        domain: domain,
        description: nil,
        keywords: [],
        packages: [],
        indicators: []
      )
      field.save!
      upgraded_field_ids << field.id if upgrading_legacy_field
      [openalex_id, field.id]
    end.tap do
      ProjectField.where(field_id: upgraded_field_ids).delete_all
    end
  end

  def project_scope
    limit ? scope.limit(limit) : scope
  end

  def classification_rows(projects, fields)
    now = Time.current

    projects.flat_map do |project|
      classifier.classify_project_fields(project).map do |prediction|
        {
          project_id: project.id,
          field_id: fields.fetch(prediction.field_id),
          confidence_score: prediction.score,
          match_signals: {
            "matched_terms" => prediction.matched_terms,
            "topic_ids" => prediction.topic_ids,
          },
          created_at: now,
          updated_at: now,
        }
      end
    end
  end
end
