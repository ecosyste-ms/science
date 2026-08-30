class FetchBriefWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: "brief", retry: 3

  def perform(project_id)
    project = Project.needing_brief_dependencies.find_by(id: project_id)
    return unless project

    project.fetch_brief
    project.reload
    project.update_science_score if project.brief.present?
  end
end
