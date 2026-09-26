class CheckSwhidVisitWorker
  include Sidekiq::Worker

  sidekiq_options queue: "swh_api", retry: 3

  def perform(project_id, request_id, event)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    return unless project

    matched = project.with_lock do
      data = project.swhids&.deep_dup
      request = data&.dig("archival")
      next false unless request && request["status"] == "pending" && request["id"] == request_id &&
        request["origin"].casecmp?(event.fetch("origin")) &&
        Time.iso8601(event.fetch("date")) >= Time.iso8601(request.fetch("attempted_at"))

      if !request["journal_event"] || event.fetch("date") > request["journal_event"].fetch("date")
        request["journal_event"] = event
        request["next_check_at"] = [Time.current, (Time.iso8601(request["retry_at"]) if request["retry_at"])].compact.max.iso8601
        project.update!(swhids: data)
      end
      true
    end
    SwhidArchiver.new(project).run if matched
  end
end
