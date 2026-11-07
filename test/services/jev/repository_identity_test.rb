require "test_helper"
require "rake"
require_relative "../../support/jev/records"

class Jev::RepositoryIdentityTest < ActiveSupport::TestCase
  include Jev::Records

  test "worker records canonical aliases without changing classification or the catalogue" do
    environment = ENV.to_h.slice("JEV_ENABLED", "JEV_API_KEY")
    ENV["JEV_ENABLED"], ENV["JEV_API_KEY"] = "true", "test-credential"
    project = Project.create!(url: "https://github.com/current/model", science_score: 60)
    ProjectRepositoryAlias.create!(project: project, url: "https://github.com/previous/model")
    candidate = discovery_candidate(status: "pending_enrich", strict_probability: 0.7,
      source_metadata: { "repository" => { "full_name" => "Previous/Model" } })
    evidence = candidate.evidence.merge("enriched" => candidate.evidence.fetch("metadata").merge("readme" => "A scientific model"))
    Jev::Evidence.any_instance.expects(:collect).returns([evidence, nil])
    stub_request(:post, Jev::Client::API).to_return(body: { model: "jev-1.14.0", answers: { implementation: { noul: 0.95 } }, usage: { input_tokens: 100, output_tokens: 20 } }.to_json)
    before = project.reload.attributes
    Jev::DiscoveryWorker.new.perform(candidate.id, "enrich")
    assert_equal "complete", candidate.reload.status, candidate.last_error
    assert_equal "research_candidate", candidate.classification
    identity = candidate.evidence.fetch("repository_identity")
    assert_equal "catalogued", identity.fetch("status")
    assert_equal project.id, identity.fetch("matches").first.fetch("project_id")
    assert_equal true, identity.fetch("matches").first.fetch("confirmed")
    refute candidate.enrich_request.request_body.fetch("state").key?("repository_identity")
    assert_equal before, project.reload.attributes
  ensure
    %w[JEV_ENABLED JEV_API_KEY].each { |key| environment.key?(key) ? ENV[key] = environment[key] : ENV.delete(key) }
  end

  test "task records README upstream hints conservatively and preserves reviews and inputs" do
    original = ENV.to_h.slice("RUN_ID", "LIMIT", "ALL")
    project = Project.create!(url: "https://github.com/canonical/model", science_score: 60)
    ProjectRepositoryAlias.create!(project: project, url: "https://github.com/previous/model")
    candidate = discovery_candidate(repository_url: "https://github.com/copy/model", status: "complete", enriched_at: Time.current,
      strict_probability: 0.8, implementation_probability: 0.96, classification: "research_candidate", review_state: "research",
      review_notes: "Confirmed scientific implementation", evidence: { "metadata" => { "name" => "model" },
        "enriched" => { "readme" => "[Build](https://github.com/previous/model/actions)\nA scientific model" } })
    before = candidate.attributes.slice("strict_probability", "implementation_probability", "classification", "review_state", "review_notes", "screen_request_id", "enrich_request_id")
    ENV["RUN_ID"], ENV["LIMIT"] = candidate.jev_run_id.to_s, "1"
    ENV.delete("ALL")
    Rails.application.load_tasks unless Rake::Task.task_defined?("jev:resolve_repositories")
    task = Rake::Task["jev:resolve_repositories"]
    task.reenable
    capture_io { task.invoke }
    identity = candidate.reload.evidence.fetch("repository_identity")
    assert_equal "possible_duplicate", identity.fetch("status")
    assert_equal project.id, identity.fetch("matches").first.fetch("project_id")
    assert_equal false, identity.fetch("matches").first.fetch("confirmed")
    assert_equal before, candidate.attributes.slice(*before.keys)
    updated_at = candidate.updated_at
    task.reenable
    capture_io { task.invoke }
    assert_equal updated_at, candidate.reload.updated_at
    assert_equal 0, candidate.run.requests.count
  ensure
    %w[RUN_ID LIMIT ALL].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
  end

  test "ordinary dependency links and non-fork source names do not suggest a duplicate" do
    project = Project.create!(url: "https://github.com/numpy/numpy", science_score: 60)
    candidate = discovery_candidate(status: "complete", enriched_at: Time.current,
      source_metadata: { "repository" => { "fork" => false, "source_name" => "numpy/numpy" } },
      evidence: { "enriched" => { "readme" => "Requires [NumPy](https://github.com/numpy/numpy)." } })
    candidate.resolve_repository!
    assert_equal "no_match", candidate.evidence.dig("repository_identity", "status")
    assert_empty candidate.evidence.dig("repository_identity", "matches")
    assert_equal 60, project.reload.science_score
  end

  test "known below-threshold identity differs from an included canonical project" do
    project = Project.create!(url: "https://github.com/current/solver", science_score: 4)
    candidate = discovery_candidate(source_metadata: { "repository" => { "html_url" => project.url } })
    candidate.resolve_repository!
    assert_equal "known_repository", candidate.evidence.dig("repository_identity", "status")
    assert_equal false, candidate.evidence.dig("repository_identity", "matches", 0, "catalogued")
  end

  test "a copy statement and a matching run candidate remain unconfirmed" do
    candidate = discovery_candidate(repository_url: "https://github.com/copy/model")
    peer = discovery_candidate(run: candidate.run, repository_url: "https://github.com/upstream/model")
    candidate.update!(evidence: { "enriched" => { "readme" => "A pure copy of [the model](https://github.com/upstream/model)." } })
    candidate.resolve_repository!
    assert_equal "possible_duplicate", candidate.evidence.dig("repository_identity", "status")
    assert_equal true, candidate.evidence.dig("repository_identity", "copy_statement")
    assert_equal peer.id, candidate.evidence.dig("repository_identity", "related_candidates", 0, "id")
  end
end
