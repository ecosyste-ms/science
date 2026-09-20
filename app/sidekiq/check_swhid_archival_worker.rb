class CheckSwhidArchivalWorker
  include Sidekiq::Worker

  sidekiq_options queue: "swhid", retry: 3

  def perform(project_id)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    SwhidArchiver.new(project).run if project
  end
end
