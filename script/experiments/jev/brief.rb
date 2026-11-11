#!/usr/bin/env ruby

require_relative "run"
require "open3"

module JevBriefExperiment
  APPLICATION_FIELDS = %w[version languages package_managers tools resources manifests dependencies lines].freeze

  def self.summary(brief)
    result = {
      "languages" => Array(brief["languages"]).map { |language| language.is_a?(Hash) ? language["name"] : language },
      "lines" => brief["lines"],
      "package_managers" => Array(brief["package_managers"]).map { |manager| manager.slice("name", "config_files") },
      "tools" => (brief["tools"] || {}).transform_values do |tools|
        tools.map { |tool| tool.slice("name", "taxonomy", "config_files") }
      end,
      "resources" => brief["resources"],
      "manifests" => brief["manifests"],
      "dependencies" => Array(brief["dependencies"]).map { |dependency| dependency.slice("name", "manifest", "ecosystem", "scope", "direct") }.uniq
    }
    result.reject { |_, value| value.nil? || value == [] || value == {} }
  end

  def self.variants(project, brief)
    base = JevExperiment.state(project, "readme")
    inspection = project.fetch("code_inspection")
    paths = { "source_file_paths" => inspection.fetch("sources").first(80),
      "source_paths_truncated" => inspection.fetch("sources").size > 80 }
    compact = summary(brief)
    {
      "readme_and_paths" => base.merge(paths),
      "readme_and_brief" => base.merge("brief" => compact),
      "readme_and_brief_and_paths" => base.merge(paths).merge("brief" => compact),
      "readme_and_brief_lines" => base.merge("brief" => compact.slice("languages", "lines")),
      "readme_and_brief_lines_and_paths" => base.merge(paths).merge("brief" => compact.slice("languages", "lines")),
      "readme_and_brief_full" => base.merge("brief" => brief.slice(*APPLICATION_FIELDS))
    }
  end

  def self.command(*args)
    output, _, status = Open3.capture3(*args)
    raise "command failed: #{args.first}" unless status.success?
    output
  end

  def self.scan(project, directory:, version:, execute: method(:command))
    inspection = project.fetch("code_inspection")
    path = inspection.fetch("path")
    revision = execute.call("git", "-C", path, "rev-parse", "HEAD").strip
    raise "checkout revision changed for #{project.fetch('url')}" unless revision == inspection.fetch("commit")
    raise "checkout contains changes for #{project.fetch('url')}" unless execute.call("git", "-C", path, "status", "--porcelain").strip.empty?
    cache_key = Digest::SHA256.hexdigest(JSON.generate([revision, version, ["brief", "-json"]]))
    cache = File.join(directory, "brief", "#{cache_key}.json")
    return JSON.parse(File.read(cache)) if File.exist?(cache)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = JSON.parse(execute.call("brief", "-json", path))
    raise "Brief output is not an object" unless raw.is_a?(Hash)
    record = { "repository" => project.fetch("url"), "commit" => revision, "command" => ["brief", "-json", path],
      "cli_version" => version, "at" => Time.now.utc.iso8601,
      "scan_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, "raw" => raw }
    FileUtils.mkdir_p(File.dirname(cache))
    File.write(cache, JSON.pretty_generate(record) + "\n")
    record
  end

  def self.run(argv, output: $stdout, transport: nil, execute: method(:command))
    options = { directory: ".claude/notes/jev/data", limit: 0.10, max_requests: 1800, repeats: 3 }
    OptionParser.new do |parser|
      parser.banner = "Usage: bundle exec ruby script/experiments/jev/brief.rb INPUT.json QUESTIONS.json [options]"
      parser.on("--directory PATH") { |value| options[:directory] = value }
      parser.on("--limit-usd N", Float) { |value| options[:limit] = value }
      parser.on("--max-requests N", Integer) { |value| options[:max_requests] = value }
      parser.on("--repeats N", Integer) { |value| options[:repeats] = value }
    end.parse!(argv)
    raise ArgumentError, "expected input and frozen questions paths" unless argv.size == 2
    raise ArgumentError, "repeats must be between 1 and 5" unless options[:repeats].between?(1, 5)
    projects = JSON.parse(File.read(argv[0]))
    questions = JSON.parse(File.read(argv[1]))
    version = execute.call("brief", "-version").strip
    runner = JevExperiment::Runner.new(**options.slice(:directory, :limit, :max_requests), transport: transport)
    projects.select { |project| project.dig("code_inspection", "status") == "ok" }.each do |project|
      scan = scan(project, directory: options[:directory], version: version, execute: execute)
      variants(project, scan.fetch("raw")).each do |variant, state|
        repeats = %w[readme_and_paths readme_and_brief readme_and_brief_lines_and_paths].include?(variant) ? options[:repeats] : 1
        repeats.times do |repeat|
          if JSON.generate(model: "jev-1.14.0", state: state, questions: questions).bytesize > 24_000
            output.puts JSON.generate(project: project["url"], variant: variant, status: "skipped", reason: "input exceeds experiment limit")
            next
          end
          result = runner.call(state: state, questions: questions,
            replicate: "brief-comparison-#{variant}-#{repeat}")
          output.puts JSON.generate(project: project["url"], variant: variant, repeat: repeat,
            key: result["key"], cached: result["cache_hit"], answers: result.dig("response", "answers"),
            usage: result.dig("response", "usage"), latency: result["latency_seconds"],
            scan_seconds: scan["scan_seconds"], brief_version: scan["cli_version"], commit: scan["commit"])
          output.flush
        end
      end
    end
  end
end

JevBriefExperiment.run(ARGV) if $PROGRAM_NAME == __FILE__
