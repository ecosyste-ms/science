class PaperAuthor < ApplicationRecord
  ROLES = %w[author editor].freeze

  belongs_to :paper
  belongs_to :author, optional: true

  validates :source, presence: true
  validates :role, inclusion: { in: ROLES }
  validates :position,
    presence: true,
    uniqueness: { scope: %i[paper_id source role] }
  validates :source_path, presence: true
  validates :source_digest, presence: true
end
