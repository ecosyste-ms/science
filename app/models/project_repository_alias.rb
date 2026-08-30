class ProjectRepositoryAlias < ApplicationRecord
  belongs_to :project

  validates :url, presence: true, uniqueness: { scope: :project_id }
end
