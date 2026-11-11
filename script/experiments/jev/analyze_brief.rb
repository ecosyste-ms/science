#!/usr/bin/env ruby

require_relative "analyze"

module JevBriefAnalysis
  QUESTIONS = %w[strict implementation implementation_plain implementation_evidence implementation_structured implementation_choice implementation_choice_reversed].freeze

  def self.probability(row, question)
    answer = row.fetch("answers").fetch(question)
    answer.key?("noul") ? answer.fetch("noul") : answer.fetch("probabilities").fetch("implementation")
  end

  def self.run(input_path, observations_path, directory)
    projects = JSON.parse(File.read(input_path)).to_h { |p| [p.fetch("url"), p] }
    observations = File.readlines(observations_path).map { |line| JSON.parse(line) }
    skipped, rows = observations.partition { |row| row["status"] == "skipped" }
    raise ArgumentError, "no observations" if rows.empty?
    variants = rows.group_by { |row| row.fetch("variant") }.transform_values do |observed|
      by_project = observed.group_by { |row| row.fetch("project") }
      question_results = QUESTIONS.select { |question| observed.first.fetch("answers").key?(question) }.to_h do |question|
        averaged = by_project.map do |url, repeats|
          project = projects.fetch(url)
          values = repeats.map { |row| probability(row, question) }
          { id: project["review_id"] || url, label: project["manual_label"], p: values.sum.fdiv(values.size) }
        end
        repeat_metrics = observed.group_by { |row| row.fetch("repeat") }.transform_values do |repeats|
          values = repeats.map do |row|
            project = projects.fetch(row.fetch("project"))
            { id: project["review_id"] || row["project"], label: project["manual_label"], p: probability(row, question) }
          end
          JevAnalysis.metrics(values, 0.8)
        end
        ranges = by_project.values.map do |repeats|
          values = repeats.map { |row| probability(row, question) }
          { range: values.max - values.min, flip: values.any? { |p| p >= 0.8 } && values.any? { |p| p < 0.8 } }
        end
        [question, { mean_probability_metrics_80: JevAnalysis.metrics(averaged, 0.8), per_repeat: repeat_metrics,
          mean_within_project_range: ranges.sum { |r| r[:range] }.fdiv(ranges.size),
          max_within_project_range: ranges.map { |r| r[:range] }.max,
          projects_crossing_80: ranges.count { |r| r[:flip] } }]
      end
      mean_tokens = observed.sum { |row| row.dig("usage", "input_tokens") }.fdiv(observed.size)
      { projects: by_project.size, calls: observed.size, mean_input_tokens: mean_tokens,
        estimated_usd: [10_000, 250_000, 1_000_000].to_h { |n| [n, n * mean_tokens * JevExperiment::PRICE / 1_000_000] },
        questions: question_results }
    end
    keys = rows.map { |row| row.fetch("key") }.uniq
    records = keys.map { |key| JSON.parse(File.read(File.join(directory, "responses", "#{key}.json"))) }
    scans = Dir[File.join(directory, "brief", "*.json")].map { |path| JSON.parse(File.read(path)) }
    selected_urls = rows.map { |r| r["project"] }.uniq
    scans.select! { |scan| selected_urls.include?(scan["repository"]) }
    scan_times = scans.map { |scan| scan.fetch("scan_seconds") }.sort
    diagnostics = rows.group_by { |row| row.fetch("project") }.to_h do |url, observed|
      project = projects.fetch(url)
      values = observed.group_by { |row| row.fetch("variant") }.transform_values do |repeats|
        QUESTIONS.select { |question| repeats.first.fetch("answers").key?(question) }.to_h do |question|
          [question, repeats.map { |row| probability(row, question) }]
        end
      end
      [url, { review_id: project["review_id"], label: project["manual_label"], variants: values }]
    end
    { variants: variants, skipped: skipped, recorded_cost_usd: records.sum { |r| r.fetch("cost_usd") },
      requests: keys.size, input_tokens: records.sum { |r| r.dig("response", "usage", "input_tokens") },
      scans: { n: scans.size, versions: scans.map { |scan| scan["cli_version"] }.uniq,
        total_seconds: scan_times.sum, median_seconds: scan_times[scan_times.size / 2],
        max_seconds: scan_times.last }, diagnostics: diagnostics }
  end
end

puts JSON.pretty_generate(JevBriefAnalysis.run(*ARGV)) if $PROGRAM_NAME == __FILE__
