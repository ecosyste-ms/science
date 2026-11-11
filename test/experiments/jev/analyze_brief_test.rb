require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../../../script/experiments/jev/run"

class JevBriefAnalysisTest < Minitest::Test
  def test_cli_counts_each_label_once_across_repeated_predictions_and_reports_threshold_variation
    Dir.mktmpdir("jev-brief-analysis") do |directory|
      FileUtils.mkdir_p(File.join(directory, "responses"))
      sample = [
        { url: "https://github.com/example/model", review_id: 1, manual_label: true },
        { url: "https://github.com/example/docs", review_id: 2, manual_label: false },
        { url: "https://github.com/example/unknown", review_id: 3, manual_label: nil }
      ]
      input = File.join(directory, "input.json")
      observations = File.join(directory, "observations.jsonl")
      File.write(input, JSON.generate(sample))
      rows = sample.flat_map do |project|
        [0, 1].map do |repeat|
          key = "#{project[:review_id]}-#{repeat}"
          p = project[:review_id] == 1 ? [0.79, 0.83][repeat] : 0.1
          File.write(File.join(directory, "responses", "#{key}.json"), JSON.generate(
            cost_usd: 0.000042, response: { usage: { input_tokens: 1000 } }))
          { project: project[:url], variant: "readme_and_brief", repeat: repeat, key: key, cached: true,
            usage: { input_tokens: 1000 }, answers: { implementation: { noul: p } } }
        end
      end
      File.write(observations, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
      output, error, status = Open3.capture3(RbConfig.ruby, "script/experiments/jev/analyze_brief.rb", input, observations, directory)
      assert status.success?, error
      result = JSON.parse(output)
      implementation = result.dig("variants", "readme_and_brief", "questions", "implementation")
      assert_equal 2, implementation.dig("mean_probability_metrics_80", "n")
      assert_equal 1, implementation.dig("mean_probability_metrics_80", "tp")
      assert_equal 1, implementation.dig("per_repeat", "0", "fn")
      assert_equal 1, implementation["projects_crossing_80"]
      assert_equal 6, result["requests"]
      assert_in_delta 6 * 0.000042, result.fetch("recorded_cost_usd")
      refute result.key?("live_cost_usd")
      assert_in_delta 42, result.dig("variants", "readme_and_brief", "estimated_usd", "1000000")
    end
  end
end
