class FetchSwhidWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: "swhid", retry: 3

  def perform(project_id)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    return unless project

    project.fetch_swhids if project.swhids.nil?
    project.check_swhid_archive
  end
end
