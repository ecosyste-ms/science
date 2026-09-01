class AuthorDeveloperAccountLink < ApplicationRecord
  SOURCES = %w[same_project_email].freeze

  belongs_to :author
  belongs_to :developer_account
  belongs_to :project, optional: true
  belongs_to :project_author, optional: true
  belongs_to :project_contributor, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :source_key,
    presence: true,
    uniqueness: { scope: :source }
  validates :matching_method, presence: true
  validates :source_digest, presence: true

  def self.unambiguous_account_ids_for(author_id)
    group(:developer_account_id)
      .having("COUNT(DISTINCT author_id) = 1")
      .having("MIN(author_id) = ?", author_id)
      .select(:developer_account_id)
  end
end
