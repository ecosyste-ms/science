require "minitest/autorun"
require "tmpdir"
require "stringio"
require "webmock/minitest"
require_relative "../../../script/experiments/jev/run"

WebMock.disable_net_connect!(allow_localhost: true)

class JevExperimentTest < Minitest::Test
  def setup
    WebMock.reset!
    @directory = Dir.mktmpdir("jev-test")
    @key = ENV["JEV_API_KEY"]
    ENV["JEV_API_KEY"] = "test-secret"
    @project = { "id" => 18, "name" => "genome-assembly", "description" => "Assembly evaluation workflow",
      "science_score" => 0, "label" => false, "keywords" => ["genomics"], "url" => "https://github.com/example/assembly",
      "repository" => { "language" => "Python", "topics" => ["bioinformatics"] } }
    @input = File.join(@directory, "input.json")
    File.write(@input, JSON.generate([@project]))
  end

  def teardown
    ENV["JEV_API_KEY"] = @key
    FileUtils.remove_entry(@directory)
  end

  def response
    { model: "jev-1.14.0", answers: { strict: { type: "noul", noul: 0.93 } },
      usage: { input_tokens: 200, output_tokens: 12 } }.to_json
  end

  def args(*extra)
    [@input, "--directory", @directory, "--variants", "metadata", "--questions", "strict", *extra]
  end

  def test_cli_sends_real_metadata_without_score_or_label_and_replays_without_another_request
    request = stub_request(:post, JevExperiment::API).with do |req|
      body = JSON.parse(req.body)
      assert_equal "Assembly evaluation workflow", body.dig("state", "description")
      assert_equal ["genomics", "bioinformatics"], body.dig("state", "topics")
      refute body["state"].key?("science_score")
      refute body["state"].key?("label")
      assert_equal "Bearer test-secret", req.headers["Authorization"]
      true
    end.to_return(body: response)
    output = StringIO.new
    2.times { JevExperiment.run(args, output: output) }
    assert_requested request, times: 1
    rows = output.string.lines.map { |line| JSON.parse(line) }
    assert_equal [false, true], rows.map { |row| row["cached"] }
    record = File.read(Dir[File.join(@directory, "responses", "*.json")].first)
    refute_includes record, "test-secret"
    ledger = JSON.parse(File.read(File.join(@directory, "ledger.json")))
    assert_in_delta 200 * 0.042 / 1_000_000, ledger.values.sum { |r| r["usd"] }
  end

  def test_cli_stops_before_network_when_budget_is_too_small
    assert_raises(RuntimeError) { JevExperiment.run(args("--limit-usd", "0.0000001"), output: StringIO.new) }
    assert_not_requested :post, JevExperiment::API
  end

  def test_cli_rejects_a_response_from_a_different_model_without_caching_it
    payload = JSON.parse(response).merge("model" => "jev-unexpected")
    stub_request(:post, JevExperiment::API).to_return(body: JSON.generate(payload))
    error = assert_raises(RuntimeError) { JevExperiment.run(args, output: StringIO.new) }
    assert_equal "unexpected response model", error.message
    assert_empty Dir[File.join(@directory, "responses", "*.json")]
    ledger = JSON.parse(File.read(File.join(@directory, "ledger.json")))
    assert_equal "reserved", ledger.values.first.fetch("status")
  end

  def test_cli_rejects_a_mismatched_cached_model_without_another_request
    request = stub_request(:post, JevExperiment::API).to_return(body: response)
    JevExperiment.run(args, output: StringIO.new)
    path = Dir[File.join(@directory, "responses", "*.json")].first
    record = JSON.parse(File.read(path))
    record.fetch("response")["model"] = "jev-unexpected"
    File.write(path, JSON.generate(record))
    error = assert_raises(RuntimeError) { JevExperiment.run(args, output: StringIO.new) }
    assert_equal "unexpected response model", error.message
    assert_requested request, times: 1
  end

  def test_unknown_outcome_keeps_reservation_and_request_limit_survives_restart
    stub_request(:post, JevExperiment::API).to_timeout
    assert_raises(Faraday::Error) { JevExperiment.run(args, output: StringIO.new) }
    ledger = JSON.parse(File.read(File.join(@directory, "ledger.json")))
    assert_equal "reserved", ledger.values.first["status"]
    assert_operator ledger.values.first["usd"], :>, 0
    error = assert_raises(RuntimeError) { JevExperiment.run(args("--max-requests", "1"), output: StringIO.new) }
    assert_equal "request limit reached", error.message
  end

  def test_prompt_or_input_change_creates_distinct_cache_entries
    stub_request(:post, JevExperiment::API).to_return(body: response)
    JevExperiment.run(args, output: StringIO.new)
    @project["description"] = "Genome sequencing analysis"
    File.write(@input, JSON.generate([@project]))
    JevExperiment.run(args, output: StringIO.new)
    assert_equal 2, Dir[File.join(@directory, "responses", "*.json")].size
  end

  def test_readme_variant_only_adds_available_text_and_bounds_its_length
    assert_equal JevExperiment.state(@project, "metadata"), JevExperiment.state(@project, "readme")
    @project["readme"] = "Climate simulation " * 1000
    assert_equal 8000, JevExperiment.state(@project, "readme").fetch("readme").length
  end

  def test_blank_project_description_falls_back_to_repository_description
    @project["description"] = " "
    @project["repository"]["description"] = "Gene expression methods"
    assert_equal "Gene expression methods", JevExperiment.state(@project, "description")["description"]
  end

  def test_default_run_keeps_the_original_question_set_when_new_experiments_are_available
    request = stub_request(:post, JevExperiment::API).with do |req|
      body = JSON.parse(req.body)
      assert_equal %w[primary workflow general education strict broad kind], body.fetch("questions").keys
      true
    end.to_return(body: JSON.generate(model: "jev-1.14.0", usage: { input_tokens: 800, output_tokens: 160 },
      answers: JevExperiment::PILOT_QUESTIONS.to_h do |name, question|
        answer = question[:type] == "choice" ? { probabilities: { research: 1.0 } } : { noul: 0.9 }
        [name, answer]
      end))
    JevExperiment.run([@input, "--directory", @directory, "--variants", "metadata"], output: StringIO.new)
    assert_requested request, times: 1
  end
end
