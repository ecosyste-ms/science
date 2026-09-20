require "tmpdir"

class ProjectSwhidScanner
  def initialize(project)
    @project = project
    @calculator = SwhidCalculator.new
  end

  def scan
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    origin = @project.repository&.dig("clone_url").presence || @project.url
    result = { "origin" => origin, "attempted_at" => Time.now.utc.iso8601 }

    Dir.mktmpdir("science-swhid-") do |directory|
      checkout = File.join(directory, "repository")
      result["clone_command"] = ["git", "clone", "--depth", "1", "--no-tags", "--", origin, checkout]
      @calculator.run(result["clone_command"])
      commit = @calculator.run(["git", "-C", checkout, "rev-parse", "HEAD"]).strip
      result["commit"] = commit
      result["revision"] = @calculator.calculate(type: "revision", path: checkout, ref: commit, origin: origin)
      result["directory"] = @calculator.calculate(type: "directory", path: checkout, origin: origin)
      result["status"] = %w[revision directory].all? { |type| result[type]["status"] == "success" } ? "success" : "error"
    end
    result
  rescue SwhidCalculator::CommandError, SystemCallError => error
    result.merge!("status" => "error", "error" => error.message.to_s.scrub[0, SwhidCalculator::ERROR_LIMIT])
  ensure
    result["duration_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round if result
  end
end
