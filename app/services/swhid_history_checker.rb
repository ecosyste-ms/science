require "tmpdir"

class SwhidHistoryChecker
  FETCH_STEP = 100
  MAX_DEPTH = 1_000
  MAX_REVISIONS = 1_000
  MAX_CHECKS = 100
  MAX_DISK_BYTES = 500.megabytes
  TIMEOUT = 120

  attr_reader :project, :data

  def initialize(project)
    @project = project
    @previous = project.swhids&.dig("history_archive")&.deep_dup
    @data = @previous&.deep_dup || {
      "starting_commit" => project.swhids&.dig("commit"),
      "origin" => project.swhids&.dig("origin").presence || project.repository&.dig("clone_url").presence || project.url,
      "status" => "incomplete", "complete" => false, "history_complete" => false,
      "depth" => 0, "revisions" => []
    }
  end

  def self.eligible
    Project.visible.scientific.with_repository
      .where("swhids->>'commit' IS NOT NULL")
      .where("swhids->'revision'->'archive'->>'status' IN ('archived', 'not_found')")
      .where("swhids->'origin_archive'->>'status' IN ('archived', 'not_found')")
  end

  def pending
    data.fetch("revisions").reject { |object| %w[archived not_found].include?(object.dig("archive", "status")) }
  end

  def prepare
    return if data["complete"] || data["status"] == "unsupported"
    return if pending.any? || data["history_complete"]
    return if data["depth"] >= MAX_DEPTH || data["revisions"].size >= MAX_REVISIONS

    data["attempted_at"] = Time.current.iso8601
    unless data["starting_commit"].to_s.match?(/\A[0-9a-f]{40}\z/)
      data.merge!("status" => "unsupported", "reason" => "unsupported_object_format")
      return persist
    end

    @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
    Dir.mktmpdir("science-swh-history-") do |directory|
      @directory = directory
      checkout = File.join(directory, "repository.git")
      run(["git", "init", "--bare", "--object-format=sha1", checkout])
      depth = [data["depth"] + FETCH_STEP, MAX_DEPTH].min
      origin = data.fetch("origin")
      credentials = ProjectRepositoryScanner.new(project).clone_credentials(origin)
      run(["git", *credentials, "-C", checkout, "-c", "gc.auto=0", "fetch", "--no-auto-maintenance",
        "--no-tags", "--filter=blob:none", "--depth=#{depth}", "--", origin, data.fetch("starting_commit")])
      commits = run(["git", "-C", checkout, "rev-list", "--topo-order", "--max-count=#{MAX_REVISIONS + 2}",
        data.fetch("starting_commit"), "--"]).lines.map(&:strip)
      shallow_file = File.join(checkout, "shallow")
      shallow = File.exist?(shallow_file) ? File.readlines(shallow_file, chomp: true) : []
      ancestors = commits.reject { |commit| commit == data["starting_commit"] }
      existing = data["revisions"].index_by { |object| object.fetch("swhid") }
      identifiers = (existing.keys + ancestors.map { |commit| "swh:1:rev:#{commit}" }).uniq
      data["revisions"] = identifiers.first(MAX_REVISIONS).map do |identifier|
        existing[identifier] || { "swhid" => identifier, "status" => "success" }
      end
      data["depth"] = depth
      data["history_complete"] = (commits & shallow).empty? && identifiers.size <= MAX_REVISIONS
      data["truncation_reason"] = if identifiers.size > MAX_REVISIONS
        "identifier_limit"
      elsif !data["history_complete"]
        depth == MAX_DEPTH ? "depth_limit" : "shallow_history"
      end
      data.delete("error")
      update_status
      persist
    end
  rescue RepositoryCommand::Error, SystemCallError => error
    data.merge!("status" => "incomplete", "complete" => false, "reason" => "fetch_failed",
      "error" => error.message.to_s.scrub[0, 500])
    persist
  end

  def run(command)
    remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise RepositoryCommand::Error, "history runtime limit exceeded" if remaining <= 0

    RepositoryCommand.new(timeout: remaining, disk_path: @directory, disk_limit: MAX_DISK_BYTES).run(command)
  end

  def update_status
    data["checked_count"] = data["revisions"].size - pending.size
    data["complete"] = data["history_complete"] && pending.empty?
    data["status"] = data["complete"] ? "complete" : "incomplete"
    data["checked_at"] = Time.current.iso8601
    data["reason"] = if pending.any?
      pending.any? { |object| object.dig("archive", "status") == "error" } ? "api_error" : "pending_checks"
    elsif !data["complete"]
      data["truncation_reason"]
    end
    data.delete("reason") if data["reason"].nil?
  end

  def persist
    project.with_lock do
      saved = project.swhids&.deep_dup
      next unless saved && saved["history_archive"] == @previous
      next unless @previous || saved["commit"] == data["starting_commit"]

      saved["history_archive"] = data
      project.update!(swhids: saved)
      @previous = data.deep_dup
    end
  end
end
