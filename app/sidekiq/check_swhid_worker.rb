class CheckSwhidWorker
  include Sidekiq::Worker

  sidekiq_options queue: "swh_api", retry: 3

  def perform(project_id)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    project.enqueue_swhid_check if project
  end
end
