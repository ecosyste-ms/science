class Author < ApplicationRecord
  has_many :identifiers,
    class_name: "AuthorIdentifier",
    dependent: :delete_all
  has_many :project_authors, dependent: :nullify
  has_many :project_contributors, dependent: :nullify
  has_many :developer_account_links,
    class_name: "AuthorDeveloperAccountLink",
    dependent: :delete_all
  has_many :developer_accounts,
    through: :developer_account_links

  validates :canonical_key,
    presence: true,
    uniqueness: { case_sensitive: false }

  def to_s
    display_name.presence || canonical_key
  end
end
