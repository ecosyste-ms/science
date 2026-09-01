class ProjectContributor < ApplicationRecord
  ACCOUNT_KINDS = %w[bot unknown].freeze

  belongs_to :project
  belongs_to :owner, optional: true
  belongs_to :author, optional: true
  belongs_to :developer_account, optional: true

  validates :source, presence: true
  validates :source_key, presence: true,
    uniqueness: { scope: %i[project_id source] }
  validates :account_kind, inclusion: { in: ACCOUNT_KINDS }
  validates :contributions_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source_digest, presence: true
end
