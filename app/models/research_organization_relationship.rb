class ResearchOrganizationRelationship < ApplicationRecord
  belongs_to :research_organization_import

  validates :kind, inclusion: { in: %w[child related successor] }
end
