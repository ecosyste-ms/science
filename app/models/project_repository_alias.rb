class ProjectRepositoryAlias < ApplicationRecord
  belongs_to :project
  after_commit :enqueue_software_search_index

  def enqueue_software_search_index
    IndexSoftwareSearchWorker.perform_async(project_id)
  end

  validates :url, presence: true, uniqueness: { scope: :project_id }
end
