require "test_helper"
require_relative "../support/jev_records"

class JevPipelineTest < ActiveSupport::TestCase
  include JevRecords
  setup do
    @environment = ENV.to_h.slice(*%w[JEV_ENABLED JEV_API_KEY JEV_TOTAL_BUDGET_USD JEV_REQUESTS_PER_SECOND])
    ENV["JEV_ENABLED"] = "true"
    ENV["JEV_API_KEY"] = "test-credential"
    ENV["JEV_TOTAL_BUDGET_USD"] = "5"
    ENV["JEV_REQUESTS_PER_SECOND"] = "40"
    @run = discovery_run
    @candidate = discovery_candidate(jev_run: @run)
  end

  teardown do
    %w[JEV_ENABLED JEV_API_KEY JEV_TOTAL_BUDGET_USD JEV_REQUESTS_PER_SECOND].each { |key| @environment.key?(key) ? ENV[key] = @environment[key] : ENV.delete(key) }
  end

  test "scheduler and workers persist both probabilities without changing projects" do
    project = Project.create!(url: @candidate.repository_url, science_score: 4, readme: "A soil water solver")
    @candidate.update!(project: project)
    before = project.reload.attributes
    screen = response("strict", 0.72)
    enrich = response("implementation", 0.94)
    JevSchedulerWorker.new.perform
    assert_equal "queued_screen", @candidate.reload.status
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal "pending_enrich", @candidate.reload.status
    state = @candidate.evidence.merge("enriched" => @candidate.evidence["metadata"].merge("source_file_paths" => ["src/soil.py"]))
    JevEvidence.any_instance.expects(:collect).with(@candidate).returns([state, nil])
    JevSchedulerWorker.new.perform
    JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
    assert_equal "complete", @candidate.reload.status
    assert_equal "research_candidate", @candidate.classification
    assert_equal 0.72, @candidate.strict_probability
    assert_equal 0.94, @candidate.implementation_probability
    assert_equal before, project.reload.attributes
    assert_equal 2, @run.jev_requests.where(status: "succeeded").count
    assert_equal 200, @run.statistics[:input_tokens]
    assert_equal BigDecimal("0.0000084"), @run.reload.spent_usd
    assert_equal 0, @run.reserved_usd
    assert_requested screen, times: 1
    assert_requested enrich, times: 1
    JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
    assert_equal 2, JevRequest.count
  end

  test "cached equivalent inputs are reused across runs and JSON key order" do
    request = response("strict", 0.1)
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    other = discovery_candidate(evidence: { "metadata" => @candidate.evidence["metadata"].to_a.reverse.to_h })
    JevDiscoveryWorker.new.perform(other.id, "screen")
    assert_equal @candidate.reload.screen_request_id, other.reload.screen_request_id
    assert_equal 0, other.jev_run.spent_usd
    assert_requested request, times: 1
  end

  test "timeout keeps a conservative reservation and retry does not repeat checkout" do
    @candidate.update!(status: "pending_enrich", strict_probability: 0.9)
    evidence = @candidate.evidence.merge("enriched" => { "readme" => "Soil solver", "source_file_paths" => ["soil.R"] })
    JevEvidence.any_instance.expects(:collect).once.returns([evidence, "Partial checkout"])
    request = stub_request(:post, JevClient::API).to_timeout
    JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
    assert_equal "pending_enrich", @candidate.reload.status
    assert_operator @run.reload.reserved_usd, :>, 0
    reserved = @run.reserved_usd
    request.to_return(body: result("implementation", 0.92).to_json)
    JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
    assert_equal "complete", @candidate.reload.status
    assert_equal "Partial checkout", @candidate.enrichment_error
    assert_equal reserved, @run.reload.reserved_usd
    assert_equal 2, @candidate.enrich_request.attempts
  end

  test "failed request retry in another run charges that run" do
    stub_request(:post, JevClient::API).to_timeout
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    other = discovery_candidate(evidence: @candidate.evidence)
    response("strict", 0.1)
    JevDiscoveryWorker.new.perform(other.id, "screen")
    assert_operator other.jev_run.reload.spent_usd, :>, 0
    assert_equal 0, @run.reload.spent_usd
    assert_operator @run.reserved_usd, :>, 0
  end

  test "budget prevents the request and pauses the run" do
    @run.update!(budget_usd: "0.00000001")
    request = response("strict", 0.9)
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal "paused", @run.reload.status
    assert_equal "pending_screen", @candidate.reload.status
    assert_equal 0, @candidate.screen_attempts
    assert_not_requested request
  end

  test "authentication failures pause without consuming the retry allowance" do
    stub_request(:post, JevClient::API).to_return(status: 401)
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal "paused", @run.reload.status
    assert_equal 0, @run.reserved_usd
    assert_equal 0, @candidate.reload.screen_attempts
    assert_equal 401, @run.jev_requests.first.attempt_log.first["http_status"]
  end

  test "invalid JSON retains its unknown charge and a safe attempt record" do
    stub_request(:post, JevClient::API).to_return(body: "broken JSON")
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal "pending_screen", @candidate.reload.status
    assert_equal "Invalid Jev JSON", @candidate.last_error
    assert_operator @run.reload.reserved_usd, :>, 0
    assert_equal "Invalid Jev JSON", @run.jev_requests.first.attempt_log.first["error"]
    refute_includes @run.jev_requests.first.to_json, ENV.fetch("JEV_API_KEY")
  end

  test "invalid probabilities and model releases are recorded as failures" do
    data = result("strict", 1.1)
    stub_request(:post, JevClient::API).to_return(body: data.to_json)
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal "pending_screen", @candidate.reload.status
    assert_match "Invalid Jev probability", @candidate.last_error
    data["model"] = "another-model"
    stub_request(:post, JevClient::API).to_return(body: data.to_json)
    2.times { JevDiscoveryWorker.new.perform(@candidate.id, "screen") }
    assert_equal "failed_screen", @candidate.reload.status
    assert_match "Unexpected Jev model", @candidate.last_error
    assert_operator @run.reload.spent_usd, :>, 0
  end

  test "disabled Jev leaves ordinary records and pending work alone" do
    ENV["JEV_ENABLED"] = "false"
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    JevSchedulerWorker.new.perform
    assert_equal "pending_screen", @candidate.reload.status
    assert_equal 0, JevRequest.count
  end

  test "a project that crosses the Science Score threshold is excluded" do
    project = Project.create!(url: @candidate.repository_url, science_score: 30)
    @candidate.update!(project: project)
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal "excluded", @candidate.reload.status
    assert_equal 0, JevRequest.count
    assert_equal 30, project.reload.science_score
  end

  test "control sampling is deterministic and includes low and borderline cases" do
    %w[low borderline].zip([0.1, 0.4]).each do |band, probability|
      response("strict", probability)
      candidates = 60.times.map { |i| discovery_candidate(jev_run: @run, repository_url: "https://github.com/discovery/control-#{band}-#{i}") }
      candidates.each { |candidate| JevDiscoveryWorker.new.perform(candidate.id, "screen") }
      controls = @run.jev_discoveries.where(screen_band: band, control: true)
      assert_operator controls.count, :>, 0
      assert controls.all? { |candidate| candidate.status == "pending_enrich" }
      assert_equal band == "low" ? 0.05 : 0.2, controls.first.control_probability
      chosen = controls.pluck(:id)
      candidates.each { |candidate| candidate.update!(status: "pending_screen") }
      candidates.each { |candidate| JevDiscoveryWorker.new.perform(candidate.id, "screen") }
      assert_equal chosen.sort, controls.pluck(:id).sort
    end
  end

  test "expired leases resume and enrichment caps leave an inspectable record" do
    @candidate.update!(status: "screening", lease_until: 1.minute.ago, processing_token: "old")
    JevSchedulerWorker.new.perform
    assert_equal "queued_screen", @candidate.reload.status
    assert_nil @candidate.processing_token
    @run.update!(settings: @run.settings.merge("max_enrichments" => 0))
    @candidate.update!(status: "pending_enrich", lease_until: nil)
    JevSchedulerWorker.new.perform
    assert_equal "enrichment_deferred", @candidate.reload.status
  end

  test "rescan detects changed source revision and explicit reevaluation reuses unchanged requests" do
    response("strict", 0.1)
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    @candidate.update!(status: "complete", next_check_at: 1.minute.ago, review_state: "negative")
    repo = { "full_name" => "discovery/solver", "pushed_at" => "2026-11-07T12:00:00Z" }
    JevEvidence.expects(:get).with(JevEvidence.repository_endpoint(@candidate.repository_url)).returns(repo)
    JevSchedulerWorker.new.perform
    assert_equal "pending_screen", @candidate.reload.status
    assert_equal "unreviewed", @candidate.review_state
    assert_nil @candidate.screen_request_id
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    requests = JevRequest.count
    @run.reevaluate!
    JevDiscoveryWorker.new.perform(@candidate.id, "screen")
    assert_equal requests, JevRequest.count
  end

  test "scheduler samples existing score strata and broad absent repositories idempotently" do
    @candidate.destroy!
    @run.update!(sampling_complete: false, target_count: 8)
    4.times { |i| Project.create!(url: "https://github.com/sample/zero-#{i}", science_score: 0) }
    4.times { |i| Project.create!(url: "https://github.com/sample/low-#{i}", science_score: 5) }
    Project.create!(url: "https://github.com/sample/already-science", science_score: 80)
    registry = PackageRegistry.create!(name: "Example", ecosystem: "npm", purl_type: "npm", url: "https://example.org")
    2.times { |i| registry.packages.create!(name: "library-#{i}", repository_url: "https://github.com/sample/library-#{i}") }
    repositories = 10.times.map { |i| { "full_name" => "external/random-#{i}", "description" => "A text editor", "fork" => false } }
    JevEvidence.stubs(:get).returns(repositories)
    before = Project.count
    JevSchedulerWorker.new.perform
    assert_equal 8, @run.jev_discoveries.count
    assert_equal 2, @run.jev_discoveries.where(sample_group: "score_zero").count
    assert_equal 1, @run.jev_discoveries.where(sample_group: "score_low").count
    assert_equal 2, @run.jev_discoveries.where(source: "packages").count
    assert_equal 3, @run.jev_discoveries.where(source: "repos").count
    assert @run.reload.sampling_complete?
    assert_equal before, Project.count
    JevSchedulerWorker.new.perform
    assert_equal 8, @run.jev_discoveries.count
    assert @run.jev_discoveries.where(source: "repos").first.source_metadata["page_frame"].present?
  end

  test "enrichment runs real git checkout and Brief without sending an outline" do
    Dir.mktmpdir("jev-test-") do |path|
      File.write(File.join(path, "README.md"), "A scientific soil water solver")
      File.write(File.join(path, "soil.py"), "def solve():\n    return 1\n")
      command = RepositoryCommand.new
      command.run(["git", "init", path])
      command.run(["git", "-C", path, "add", "."])
      command.run(["git", "-C", path, "-c", "user.name=Test", "-c", "user.email=test@example.org", "-c", "commit.gpgsign=false", "commit", "-m", "Add solver"])
      checkout = RepositoryCheckout.new(path, skip_lfs: true, partial: true)
      RepositoryCheckout.expects(:new).with(@candidate.repository_url, skip_lfs: true, partial: true, disk_limit: 200.megabytes).returns(checkout)
      response("implementation", 0.95)
      @candidate.update!(status: "pending_enrich", strict_probability: 0.7)
      JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
      assert_equal "complete", @candidate.reload.status, @candidate.last_error
      assert_nil @candidate.enrichment_error
      evidence = @candidate.evidence
      assert_match(/\A[0-9a-f]{40}\z/, evidence["revision"])
      assert_equal ["soil.py"], evidence.dig("enriched", "source_file_paths")
      assert_includes evidence.dig("enriched", "brief", "languages"), "Python"
      assert evidence.dig("enriched", "brief", "lines").present?
      assert_equal %w[languages lines], evidence.dig("enriched", "brief").keys.sort
      assert_equal "A scientific soil water solver", evidence.dig("enriched", "readme")
    end
  end

  test "deleted repositories preserve incomplete evidence for review" do
    RepositoryCheckout.any_instance.expects(:open).raises(RepositoryCommand::Error, "Repository not found")
    response("implementation", 0.1)
    @candidate.update!(status: "pending_enrich", strict_probability: 0.9)
    JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
    assert_equal "complete", @candidate.reload.status
    assert_equal false, @candidate.evidence["source_paths_complete"]
    assert_match "checkout failed", @candidate.enrichment_error
    assert_equal "uncertain", @candidate.classification
  end

  test "missing line counts remain visible as an evidence gap" do
    Dir.mktmpdir("jev-missing-lines-") do |path|
      File.write(File.join(path, "README.md"), "A solver")
      command = mock
      command.stubs(:run).returns("a" * 40, "README.md\0")
      RepositoryCommand.stubs(:new).returns(command)
      RepositoryCheckout.any_instance.stubs(:open).yields(path, @candidate.repository_url, [])
      RepositoryBriefScan.expects(:call).with(path).returns({ "version" => "0.14.2", "languages" => [{ "name" => "Python" }], "lines" => nil })
      response("implementation", 0.7)
      @candidate.update!(status: "pending_enrich", strict_probability: 0.7)
      JevDiscoveryWorker.new.perform(@candidate.id, "enrich")
      assert_equal "complete", @candidate.reload.status
      assert_equal "Brief line counts unavailable", @candidate.enrichment_error
    end
  end

  def result(name, probability)
    { "model" => "jev-1.14.0", "answers" => { name => { "noul" => probability } }, "usage" => { "input_tokens" => 100, "output_tokens" => 0 } }
  end

  def response(name, probability)
    stub_request(:post, JevClient::API).with { |request| JSON.parse(request.body)["questions"].key?(name) }
      .to_return(body: result(name, probability).to_json)
  end
end
