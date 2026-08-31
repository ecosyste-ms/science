class ProjectAuthor < ApplicationRecord
  AUTHORSHIP_KINDS = %w[software preferred_citation].freeze
  AUTHOR_KINDS = %w[person organization].freeze

  belongs_to :project

  validates :source, presence: true
  validates :authorship_kind, inclusion: { in: AUTHORSHIP_KINDS }
  validates :author_kind, inclusion: { in: AUTHOR_KINDS }
  validates :position, presence: true,
    uniqueness: { scope: %i[project_id source authorship_kind] }
  validates :source_path, presence: true
  validates :source_digest, presence: true
end
