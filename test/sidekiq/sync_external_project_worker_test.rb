require "test_helper"

class SyncExternalProjectWorkerTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(url: "https://github.com/scientific-lab/arrays", science_score: 0, last_synced_at: 2.days.ago)
    ExternalProjectSync.request(@project.id)
    @request = ExternalProjectSync.sole
    SyncExternalProjectWorker.clear
    Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
    clear_sync_locks
  end
  teardown do
    SyncExternalProjectWorker.clear
    RepositoryScanWorker.clear
    clear_sync_locks
  end

  def clear_sync_locks
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncExternalProjectWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def perform
    ExternalProjectSync.enqueue_pending
    SyncExternalProjectWorker.perform_one
  end

  test "pending sync enters the normal project worker and records its completion" do
    repository = { full_name: "scientific-lab/arrays", html_url: @project.url, owner: "scientific-lab",
      host: { name: "GitHub", kind: "github", url: "https://github.com" }, metadata: { files: {} }, topics: [] }
    stub_request(:get, @project.url).to_return(status: 200)
    stub_request(:get, @project.repos_api_url).to_return(status: 200, body: repository.to_json)
    # Unrelated enrichment services are isolated; URL lookup, persistence and scoring run normally.
    %i[fetch_owner find_or_create_owner fetch_dependencies fetch_packages import_mentions
      fetch_readme fetch_commits fetch_events fetch_issue_stats sync_issues fetch_citation_file
      fetch_codemeta fetch_zenodo_file sync_releases update_committers update_keywords_from_contributors].each do |method|
      Project.any_instance.stubs(method)
    end
    perform
    assert_equal "scientific-lab/arrays", @project.reload.repository["full_name"]
    assert @project.last_synced_at > 1.minute.ago
    assert_not_nil @project.science_score_breakdown
    assert_equal @request.requested_at, @request.reload.completed_at
    assert_empty ExternalProjectSync.pending
    SyncProjectWorker.any_instance.expects(:perform).never
    SyncExternalProjectWorker.new.perform(@request.id)
  end

  test "overlapping jobs skip an active lease and an expired lease can recover" do
    SyncProjectWorker.any_instance.expects(:perform).never
    @request.update!(lease_token: "interrupted", lease_expires_at: 1.hour.from_now)
    SyncExternalProjectWorker.new.perform(@request.id)
    assert_nil @request.reload.completed_at
    SyncProjectWorker.any_instance.unstub(:perform)
    travel 61.minutes do
      SyncProjectWorker.any_instance.expects(:perform).with(@project.id).once
      perform
    end
    assert @request.reload.completed_at
    assert_nil @request.lease_token
  end

  test "failed sync is retained and due recovery retries it" do
    SyncProjectWorker.any_instance.stubs(:perform).raises(RuntimeError, "enrichment unavailable")
    assert_raises(RuntimeError) { SyncExternalProjectWorker.new.perform(@request.id) }
    assert_nil @request.reload.completed_at
    assert_nil @request.lease_token
    assert_match "enrichment unavailable", @request.last_error
    assert_empty ExternalProjectSync.due
    SyncProjectWorker.any_instance.unstub(:perform)
    travel 61.minutes do
      SyncProjectWorker.any_instance.expects(:perform).with(@project.id)
      perform
    end
    assert_nil @request.reload.last_error
    assert_empty ExternalProjectSync.pending
  end

  test "evidence arriving during enrichment remains pending after the earlier request completes" do
    original = @request.requested_at
    SyncProjectWorker.any_instance.stubs(:perform).with(@project.id).returns(nil)
    token, requested = @request.claim
    travel 1.second do
      ExternalProjectSync.request(@project.id)
      @request.finish(token, requested)
      assert_equal original, @request.reload.completed_at
      assert_equal 1, ExternalProjectSync.pending.count
      perform
    end
    assert_empty ExternalProjectSync.pending
  end

  test "owners hidden after discovery skip network requests and project mutations" do
    host = Host.create!(name: "GitHub", url: "https://github.com", kind: "github")
    owner = host.owners.create!(login: "scientific-lab", hidden: false)
    @project.update!(owner_record: owner)
    owner.update!(hidden: true)
    before = @project.reload.attributes
    perform
    assert_equal before, @project.reload.attributes
    assert_empty ExternalProjectSync.pending
    assert_not_requested :any, /https:/
  end

  test "queue recovery remains bounded and repeated scheduling deduplicates jobs" do
    other = Project.create!(url: "https://github.com/scientific-lab/other")
    ExternalProjectSync.request(other.id)
    2.times { assert_equal 1, ExternalProjectSync.enqueue_pending(limit: 1) }
    assert_equal 1, SyncExternalProjectWorker.jobs.size
    assert_equal 2, ExternalProjectSync.pending.count
  end
end
