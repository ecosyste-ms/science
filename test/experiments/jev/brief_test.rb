require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../../../script/experiments/jev/brief"

class JevBriefExperimentTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("jev-brief-test")
    @input = File.join(@directory, "input.json")
    @questions = File.join(@directory, "questions.json")
    File.write(@input, JSON.generate([{ "url" => "https://github.com/example/flux", "description" => "Flux model validation",
      "readme" => "Compares model predictions with observed flux measurements.", "manual_label" => true,
      "code_inspection" => { "status" => "ok", "path" => "/tmp/example-flux", "commit" => "abc", "sources" => ["R/validate.R"] } }]))
    File.write(@questions, JSON.generate("implementation" => { type: "noul", instructions: "Is research software implemented here?" }))
    @brief = { "version" => "test", "path" => "/tmp/example-flux", "git" => { "commit_count" => 1 },
      "languages" => [{ "name" => "R", "description" => "Statistical computing", "homepage" => "https://example.test" }],
      "tools" => { "docs" => [{ "name" => "R Markdown", "taxonomy" => { "function" => ["literate-programming"] } }] },
      "lines" => { "total_lines" => 200, "by_language" => { "R" => 190, "Markdown" => 10 } },
      "resources" => { "readme" => "README.md" }, "stats" => { "files_checked" => 500 } }
    @scans = 0
    @execute = lambda do |*command|
      case command
      when ["brief", "-version"] then "brief test\n"
      when ["git", "-C", "/tmp/example-flux", "rev-parse", "HEAD"] then "abc\n"
      when ["git", "-C", "/tmp/example-flux", "status", "--porcelain"] then ""
      when ["brief", "-json", "/tmp/example-flux"]
        @scans += 1
        JSON.generate(@brief)
      else raise "unexpected command"
      end
    end
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_cli_compares_frozen_inputs_repeats_and_replays_without_scan_or_inference
    payloads = []
    transport = lambda do |payload|
      payloads << payload
      { "model" => "jev-1.14.0", "usage" => { "input_tokens" => 500, "output_tokens" => 20 },
        "answers" => { "implementation" => { "type" => "noul", "noul" => 0.9 } } }
    end
    output = StringIO.new
    2.times do
      JevBriefExperiment.run([@input, @questions, "--directory", @directory, "--repeats", "3"],
        output: output, transport: transport, execute: @execute)
    end
    assert_equal 1, @scans
    assert_equal 12, payloads.size
    rows = output.string.lines.map { |line| JSON.parse(line) }
    assert rows.last(12).all? { |row| row["cached"] }
    payloads.each do |payload|
      refute payload["state"].key?("manual_label")
      assert_equal "Compares model predictions with observed flux measurements.", payload.dig("state", "readme")
      refute payload.dig("state", "brief")&.key?("path")
      refute payload.dig("state", "brief")&.key?("git")
      refute payload.dig("state", "brief")&.key?("stats")
    end
    compact = payloads.find { |payload| payload.dig("state", "brief", "languages") == ["R"] }
    assert_equal 190, compact.dig("state", "brief", "lines", "by_language", "R")
    assert_equal ["literate-programming"], compact.dig("state", "brief", "tools", "docs", 0, "taxonomy", "function")
  end

  def test_changed_revision_stops_before_scan_or_inference
    execute = lambda do |*command|
      command.first == "brief" ? "brief test" : "changed"
    end
    error = assert_raises(RuntimeError) do
      JevBriefExperiment.run([@input, @questions, "--directory", @directory], execute: execute,
        transport: ->(_) { flunk "inference must not run" })
    end
    assert_match "checkout revision changed", error.message
    assert_equal 0, @scans
  end
end
