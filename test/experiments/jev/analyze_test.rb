require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../../../script/experiments/jev/run"

class JevAnalysisTest < Minitest::Test
  def test_command_counts_projects_once_and_reports_each_replicate
    Dir.mktmpdir("jev-repeat-analysis") do |directory|
      FileUtils.mkdir_p(File.join(directory, "responses"))
      input = File.join(directory, "sample.json")
      File.write(input, JSON.generate([
        { id: 1, manual_label: true, science_score: 0 },
        { id: 2, manual_label: false, science_score: 82 }
      ]))
      rows = [[1, "first"], [1, "second"], [1, "third"], [2, "first"]].map do |id, replicate|
        key = "#{id}-#{replicate}"
        File.write(File.join(directory, "responses", "#{key}.json"), JSON.generate(
          key: key, replicate: replicate, latency_seconds: 0.2, cost_usd: 0.000042,
          response: { usage: { input_tokens: 1000, output_tokens: 10 } }))
        { project: id, variant: "metadata", key: key, answers: { strict: { noul: 0.9 } } }
      end
      observations = File.join(directory, "observations.jsonl")
      File.write(observations, (rows + [rows.first]).map { |row| JSON.generate(row) }.join("\n") + "\n")
      output, error, status = Open3.capture3(RbConfig.ruby, "script/experiments/jev/analyze.rb", input, observations, directory)
      assert status.success?, error
      result = JSON.parse(output)
      variant = result.fetch("variants").fetch("metadata")
      strict = variant.fetch("strategies").fetch("strict")
      assert_equal 2, variant.fetch("n")
      assert_equal 2, strict.dig("at_50", "n")
      assert_in_delta 0.5, strict.dig("at_50", "precision")
      assert_in_delta 0.41, strict.dig("at_50", "brier")
      assert_equal 2, variant.dig("score_baseline", "n")
      assert_equal 3, variant.fetch("rows").find { |row| row["id"] == 1 }.fetch("predictions")
      replicates = strict.fetch("per_replicate").to_h { |row| [row.fetch("replicate"), row] }
      assert_equal 2, replicates.dig("first", "at_50", "n")
      assert_equal 1, replicates.dig("second", "at_50", "n")
      assert_equal 1, replicates.dig("third", "at_50", "n")
      assert_equal 4, result.fetch("requests")
    end
  end

  def test_command_reports_independent_labels_and_excludes_unknowns
    Dir.mktmpdir("jev-analysis") do |directory|
      FileUtils.mkdir_p(File.join(directory, "responses"))
      projects = [
        { id: 1, manual_label: true, science_score: 8 },
        { id: 2, manual_label: false, science_score: 82 },
        { id: 3, manual_label: nil, science_score: 0 }
      ]
      File.write(File.join(directory, "sample.json"), JSON.generate(projects))
      observations = projects.map do |p|
        { project: p[:id], variant: "metadata", key: p[:id].to_s,
          answers: { strict: { noul: p[:id] == 1 ? 0.9 : 0.1 } } }
      end
      File.write(File.join(directory, "observations.jsonl"), observations.map { |r| JSON.generate(r) }.join("\n"))
      projects.each do |p|
        File.write(File.join(directory, "responses", "#{p[:id]}.json"), JSON.generate(
          key: p[:id].to_s, latency_seconds: 0.2, cost_usd: 0.000042,
          response: { usage: { input_tokens: 1000, output_tokens: 10 } }))
      end
      output, error, status = Open3.capture3(RbConfig.ruby, "script/experiments/jev/analyze.rb",
        File.join(directory, "sample.json"), File.join(directory, "observations.jsonl"), directory)
      assert status.success?, error
      result = JSON.parse(output)
      strict = result.dig("variants", "metadata", "strategies", "strict", "at_50")
      assert_equal 2, strict["n"]
      assert_equal 1, strict["tp"]
      assert_equal 1, strict["tn"]
      assert_in_delta 0.01, strict["brier"]
      assert_equal 0, result.dig("variants", "metadata", "score_baseline", "tp")
      assert_equal 3000, result["input_tokens"]
      assert_in_delta 42, result.dig("estimates", "metadata", "projects", "1000000")
    end
  end
end
