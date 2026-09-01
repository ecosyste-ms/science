class AuthorPublicEvidenceCounter
  DEFAULT_LIMIT = 1_000
  MAX_LIMIT = 10_000
  REFRESH_BATCH_SIZE = 500

  def self.sync_batch!(limit: DEFAULT_LIMIT, after_id: 0)
    limit = Integer(limit, exception: false)
    after_id = Integer(after_id, exception: false)
    unless limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end
    unless after_id && after_id >= 0
      raise ArgumentError, "after_id must be zero or greater"
    end

    author_ids = Author.where("id > ?", after_id).order(:id).limit(limit).pluck(:id)
    result = refresh!(author_ids)
    result.merge(
      selected: author_ids.length,
      next_after_id: author_ids.last,
      complete: author_ids.length < limit
    )
  end

  def self.refresh!(author_ids)
    author_ids = Array(author_ids).compact.map(&:to_i).uniq
    result = { authors: author_ids.length, updated: 0 }

    author_ids.each_slice(REFRESH_BATCH_SIZE) do |batch|
      counts = public_evidence_counts(batch)
      counts.group_by { |_, count| count }.each do |count, entries|
        ids = entries.map(&:first)
        result[:updated] += Author
          .where(id: ids)
          .where.not(public_evidence_count: count)
          .update_all(public_evidence_count: count)
      end
    end

    result
  end

  def self.refresh_for_projects!(project_ids)
    refresh!(author_ids_for_projects(project_ids))
  end

  def self.author_ids_for_projects(project_ids)
    project_ids = Array(project_ids) unless project_ids.is_a?(ActiveRecord::Relation)
    project_author_ids = ProjectAuthor
      .where.not(author_id: nil)
      .where(project_id: project_ids)
      .distinct
      .pluck(:author_id)
    contributor_author_ids = ProjectContributor
      .where.not(author_id: nil)
      .where(project_id: project_ids)
      .distinct
      .pluck(:author_id)
    paper_author_ids = PaperAuthor
      .where.not(author_id: nil)
      .joins(paper: :mentions)
      .where(mentions: { project_id: project_ids })
      .distinct
      .pluck(:author_id)

    (project_author_ids + contributor_author_ids + paper_author_ids).uniq
  end

  def self.public_evidence_counts(author_ids)
    counts = author_ids.index_with(0)
    public_project_ids = Project
      .left_outer_joins(:owner_record)
      .scientific
      .where(owners: { hidden: [false, nil] })
      .select(:id)

    ProjectAuthor
      .where.not(author_id: nil)
      .where(author_id: author_ids, project_id: public_project_ids)
      .group(:author_id)
      .count
      .each { |author_id, count| counts[author_id] += count }

    ProjectContributor
      .where.not(author_id: nil)
      .where(author_id: author_ids, project_id: public_project_ids)
      .group(:author_id)
      .count
      .each { |author_id, count| counts[author_id] += count }

    PaperAuthor
      .where.not(author_id: nil)
      .joins(paper: :mentions)
      .where(
        author_id: author_ids,
        mentions: { project_id: public_project_ids }
      )
      .group(:author_id)
      .distinct
      .count(:id)
      .each { |author_id, count| counts[author_id] += count }

    counts
  end
end
