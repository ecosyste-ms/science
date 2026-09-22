class FetchSwhidWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: "swhid", retry: 3

  def perform(project_id)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    return unless project

    project.swhid_scan_due? ? RepositoryScanWorker.new.perform(project.id) : project.enqueue_swhid_check
  end
end
