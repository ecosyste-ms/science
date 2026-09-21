class ReleaseTagDeduplicator
  MAX_GROUP_SIZE = 1_000
  TAG_ATTRIBUTES = (Release::TAG_ATTRIBUTES.values - ["tag_name"] + ["tag_fetched_at"]).freeze

  def self.run(limit: 100, after_id: 0, dry_run: true)
    limit = Integer(limit)
    after_id = Integer(after_id)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.between?(1, 100)
    raise ArgumentError, "after_id must be nonnegative" if after_id.negative?

    groups = Release.where.not(tag_name: nil)
      .select("project_id, tag_name, MIN(id) AS id").group(:project_id, :tag_name)
      .having("COUNT(1) > 1 AND MIN(id) > ?", after_id)
      .order(Arel.sql("MIN(id) ASC")).limit(limit)
    result = { selected: 0, removable: 0, removed: 0, linked_versions: 0,
      undated: 0, oversized: 0, missing_projects: 0,
      dry_run: dry_run, last_id: after_id, examples: [] }

    groups.each do |group|
      result[:selected] += 1
      result[:last_id] = group.id
      project = Project.find_by(id: group.project_id)
      unless project
        result[:missing_projects] += 1
        next
      end

      project.with_lock do
        records = project.releases.where(tag_name: group.tag_name)
          .order(:id).limit(MAX_GROUP_SIZE + 1).lock.to_a
        next if records.length < 2

        example = { project_id: project.id, tag_name: group.tag_name }
        if records.length > MAX_GROUP_SIZE
          result[:oversized] += 1
          example[:outcome] = "group exceeds #{MAX_GROUP_SIZE} rows"
        elsif records.none?(&:forge_release?) || records.any? { |record| record.forge_release? && record.published_at.nil? }
          result[:undated] += 1
          example[:outcome] = "cannot rank undated forge releases"
        else
          keeper = records.select(&:forge_release?).max_by { |record| [record.published_at, record.id] }
          tag = records.select(&:tag_fetched_at).max_by { |record| [record.tag_fetched_at, record.id] }
          removed_ids = records.map(&:id) - [keeper.id]
          versions = PackageVersion.where(release_id: removed_ids)
          result[:removable] += removed_ids.length
          result[:linked_versions] += versions.count
          unless dry_run
            keeper.update!(tag.attributes.slice(*TAG_ATTRIBUTES)) if tag && tag.id != keeper.id
            versions.update_all(release_id: nil, release_match_method: nil)
            result[:removed] += project.releases.where(id: removed_ids).delete_all
          end
          example.merge!(retained_id: keeper.id, retained_uuid: keeper.uuid,
            published_at: keeper.published_at, removed_ids: removed_ids,
            tag_metadata_id: tag&.id, outcome: dry_run ? "would retain newest release" : "retained newest release")
        end
        result[:examples] << example if result[:examples].length < 10
      end
    end
    result
  end
end
