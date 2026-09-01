class AuthorIdentifier < ApplicationRecord
  SCHEMES = %w[email openalex orcid].freeze

  belongs_to :author

  validates :scheme, inclusion: { in: SCHEMES }
  validates :value,
    presence: true,
    uniqueness: { scope: :scheme, case_sensitive: false }

  scope :publicly_displayable, -> {
    where(publicly_visible: true).where.not(scheme: "email")
  }

  def public_url
    return unless publicly_visible? && scheme != "email"

    case scheme
    when "orcid"
      "https://orcid.org/#{value}"
    when "openalex"
      value.start_with?("http://", "https://") ? value : "https://openalex.org/#{value}"
    end
  end
end
