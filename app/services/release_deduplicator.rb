class ReleaseDeduplicator
  MAX_GROUP_SIZE = 100
  IGNORED_ATTRIBUTES = %w[id created_at updated_at last_synced_at tag_fetched_at release_fetched_at].freeze

  def self.run(limit: 100, after_id: 0, dry_run: true)
    limit = Integer(limit)
    after_id = Integer(after_id)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.between?(1, 100)
    raise ArgumentError, "after_id must be nonnegative" if after_id.negative?

    groups = Release.where.not(uuid: [nil, ""]).where.not(tag_name: [nil, ""])
      .select("project_id, tag_name, uuid, MIN(id) AS id")
      .group(:project_id, :tag_name, :uuid)
      .having("COUNT(1) > 1 AND MIN(id) > ?", after_id)
      .order(Arel.sql("MIN(id) ASC")).limit(limit)
    result = { selected: 0, removable: 0, removed: 0, conflicts: 0, differing_payloads: 0,
      oversized: 0, missing_projects: 0, dry_run: dry_run, last_id: after_id, examples: [] }
    groups.each do |group|
      result[:selected] += 1
      result[:last_id] = group.id
      project = Project.find_by(id: group.project_id)
      unless project
        result[:missing_projects] += 1
        next
      end

      project.with_lock do
        tags = project.releases.where(tag_name: group.tag_name)
        if tags.where("uuid IS DISTINCT FROM ?", group.uuid).exists?
          result[:conflicts] += 1
        end
        duplicates = tags.where(uuid: group.uuid)
        records = duplicates.order(:id).limit(MAX_GROUP_SIZE + 1).lock.to_a
        if records.length > MAX_GROUP_SIZE
          result[:oversized] += 1
          outcome = "group exceeds #{MAX_GROUP_SIZE} rows"
        elsif records.length < 2
          next
        elsif records.map { |record| record.attributes.except(*IGNORED_ATTRIBUTES) }.uniq.length > 1
          result[:differing_payloads] += 1
          outcome = "different stored metadata"
        else
          keeper = records.first
          result[:removable] += records.length - 1
          result[:removed] += duplicates.where(id: records.drop(1).map(&:id)).delete_all unless dry_run
          outcome = dry_run ? "would retain #{keeper.id}" : "retained #{keeper.id}"
        end
        if result[:examples].length < 10
          result[:examples] << { project_id: project.id, tag_name: group.tag_name, uuid: group.uuid, outcome: outcome }
        end
      end
    end
    result
  end
end
