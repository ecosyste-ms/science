class DeveloperAccountIdentifier < ApplicationRecord
  SCHEMES = %w[login owner provider].freeze

  belongs_to :developer_account
  belongs_to :host

  validates :scheme, inclusion: { in: SCHEMES }
  validates :value,
    presence: true,
    uniqueness: {
      scope: %i[host_id scheme],
      case_sensitive: false,
    }
end
