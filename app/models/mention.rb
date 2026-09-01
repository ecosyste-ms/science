class Mention < ApplicationRecord
  belongs_to :paper
  belongs_to :project
  has_many :sources,
    class_name: "MentionSource",
    dependent: :delete_all

  counter_culture :paper
  counter_culture :project

  before_destroy :capture_public_evidence_author_ids
  after_commit :refresh_public_evidence_counts, on: %i[create update]
  after_destroy_commit :refresh_destroyed_public_evidence_counts

  def refresh_public_evidence_counts
    paper_ids = if saved_change_to_paper_id?
      saved_change_to_paper_id.compact
    else
      [paper_id]
    end
    author_ids = PaperAuthor
      .where.not(author_id: nil)
      .where(paper_id: paper_ids)
      .distinct
      .pluck(:author_id)
    AuthorPublicEvidenceCounter.refresh!(author_ids)
  end

  def capture_public_evidence_author_ids
    @public_evidence_author_ids = PaperAuthor
      .where.not(author_id: nil)
      .where(paper_id: paper_id)
      .distinct
      .pluck(:author_id)
  end

  def refresh_destroyed_public_evidence_counts
    AuthorPublicEvidenceCounter.refresh!(@public_evidence_author_ids)
  end
end
