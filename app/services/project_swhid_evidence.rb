class ProjectSwhidEvidence
  def initialize(project)
    @project = project
  end

  def as_json(*)
    data = @project.swhids || {}
    {
      project_id: @project.id, repository_url: @project.url,
      status: data.fetch("status", "unchecked"),
      observed_commit: data["commit"], attempted_at: data["attempted_at"],
      objects: %w[revision directory].map do |type|
        object = data[type] || {}
        {
          type: type, swhid: object["swhid"], status: object.fetch("status", "unchecked"),
          method: object["method"], attempted_at: object["attempted_at"],
          archive: (object["archive"] || { "status" => "unchecked" }).slice(
            "status", "checked_at", "attempted_at", "retry_at", "first_check"
          )
        }
      end,
      origin_archive: origin_evidence(data["origin_archive"]),
      history_archive: history_evidence(data["history_archive"]),
      bytes_verified: false
    }
  end

  def history_evidence(history)
    return { status: "unchecked" } unless history

    history.slice("status", "starting_commit", "complete", "history_complete", "depth", "reason",
      "attempted_at", "checked_at", "checked_count").merge(
      "revisions" => Array(history["revisions"]).map do |object|
        { "swhid" => object["swhid"], "archive" => (object["archive"] || { "status" => "unchecked" })
          .slice("status", "checked_at", "attempted_at", "retry_at") }
      end
    )
  end

  def origin_evidence(coverage)
    return { status: "unchecked", observations: [] } unless coverage

    coverage.slice("status", "checked_at", "retry_at", "origins", "complete", "unchecked_origins",
      "repository_url", "current_origins", "freshness_complete", "freshness_retry_at").merge(
      "observations" => Array(coverage["observations"]).map do |observation|
        observation.slice("origin", "status", "visit", "prior_visit", "latest_attempt", "checked_at",
          "attempted_at", "lookup_complete", "history_complete", "next_visit", "history_cutoff",
          "origin_role", "freshness_complete", "latest_attempt_checked_at")
      end
    )
  end
end
