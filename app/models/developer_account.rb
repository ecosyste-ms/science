class DeveloperAccount < ApplicationRecord
  ACCOUNT_KINDS = %w[bot unknown].freeze

  belongs_to :host
  belongs_to :owner, optional: true
  has_many :identifiers,
    class_name: "DeveloperAccountIdentifier",
    dependent: :delete_all
  has_many :project_contributors, dependent: :nullify
  has_many :author_links,
    class_name: "AuthorDeveloperAccountLink",
    dependent: :delete_all
  has_many :authors, through: :author_links

  validates :canonical_key,
    presence: true,
    uniqueness: { case_sensitive: false }
  validates :account_kind, inclusion: { in: ACCOUNT_KINDS }
  validates :owner_id, uniqueness: true, allow_nil: true
end
