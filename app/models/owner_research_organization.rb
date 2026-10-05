class OwnerResearchOrganization < ApplicationRecord
  belongs_to :owner
  belongs_to :research_organization

  validates :source, inclusion: { in: %w[ror manual] }
  validates :match_status, inclusion: { in: %w[matched ambiguous rejected superseded] }
  validates :relationship, inclusion: { in: %w[repository_owner] }
  validates :match_method, :observed_at, presence: true

  scope :confirmed, -> { joins(:owner).merge(Owner.visible).where(match_status: "matched") }
end
