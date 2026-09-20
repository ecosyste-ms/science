class SyncProjectReleasesWorker
  include Sidekiq::Worker

  sidekiq_options retry: 3

  def perform(project_id, source)
    project = Project.visible.find_by(id: project_id)
    ProjectReleaseSync.new(project, source).sync! if project
  end
end
