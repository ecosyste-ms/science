require "test_helper"
require_relative "../../support/jev/records"

class Jev::OwnerSamplingTest < ActiveSupport::TestCase
  include Jev::Records

  setup do
    @enabled = ENV["JEV_ENABLED"]
    ENV["JEV_ENABLED"] = "true"
    @run = discovery_run(sampling_complete: false, target_count: 30, sampling_state: { "local_done" => true, "packages_done" => true })
    @host_url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub"
    stub_request(:get, @host_url).to_return(body: { created_at: "2022-05-30T11:31:42Z", owners_count: 38_593_712 }.to_json)
    @owners = %w[alpha middle-user zeta].map { |login| { "login" => login, "kind" => "user", "created_at" => "2024-05-30T12:00:00Z" } }
    @owner_request = stub_request(:get, "#{@host_url}/owners")
      .with(query: hash_including("sort" => "created_at", "order" => "asc", "per_page" => "20", "page" => "1"))
      .to_return(body: @owners.to_json)
  end

  teardown do
    @enabled ? ENV["JEV_ENABLED"] = @enabled : ENV.delete("JEV_ENABLED")
  end

  test "scheduler samples ordinary owners with persistent dates and no project writes" do
    repositories = stub_request(:get, %r{#{@host_url}/owners/[^/]+/repositories})
      .with(query: hash_including("per_page" => "100", "fork" => "false", "sort" => "created_at"))
      .to_return do |request|
        owner = request.uri.path.split('/')[-2]
        { body: 10.times.map { |i| { full_name: "#{owner}/tool-#{i}", description: "A text editor", fork: false } }.to_json }
      end
    before = [Project.count, Package.count, Owner.count]
    Jev::SchedulerWorker.new.perform
    assert @run.reload.sampling_complete?
    assert_equal 30, @run.discoveries.count
    assert_equal before, [Project.count, Package.count, Owner.count]
    assert_equal ["seeded_owner_time_window"], @run.discoveries.distinct.pluck(:sampling_method)
    assert_equal ["external_owner_user"], @run.discoveries.distinct.pluck(:sample_group)
    assert_equal 3, @run.discoveries.map { |candidate| candidate.source_metadata.dig("owner", "login") }.uniq.size
    frame = @run.sampling_state.fetch("owner_frame")
    assert_equal 38_593_712, frame["owners_count"]
    @run.discoveries.each do |candidate|
      assert_equal frame, candidate.source_metadata["owner_frame"]
      assert_operator Time.iso8601(candidate.source_metadata.fetch("created_after")), :>=, Time.iso8601(frame.fetch("start"))
      assert_equal "queued_screen", candidate.status
    end
    Jev::SchedulerWorker.new.perform
    assert_requested @owner_request, times: 1
    assert_requested repositories, times: 3
  end

  test "failed owner resumes its checkpoint without repeating completed owners" do
    request = stub_request(:get, %r{#{@host_url}/owners/[^/]+/repositories}).to_return do |http|
      owner = http.uri.path.split('/')[-2]
      { body: [{ full_name: "#{owner}/tool", fork: false }].to_json }
    end
    Jev::SchedulerWorker.new.perform
    window = @run.reload.sampling_state.fetch("owner_window")
    assert_equal 3, window["owner_index"]
    assert_equal 3, @run.discoveries.count
    frame = @run.sampling_state.fetch("owner_frame")
    @run.update!(sampling_state: @run.sampling_state.merge("owner_window" => window.merge("owner_index" => 1)))
    owner = window.fetch("owners")[1].fetch("login")
    failure = stub_request(:get, "#{@host_url}/owners/#{owner}/repositories")
      .with(query: hash_including("fork" => "false")).to_return(status: 503)
    Jev::SchedulerWorker.new.perform
    assert_equal 1, @run.reload.sampling_state.dig("owner_window", "owner_index")
    assert_equal frame, @run.sampling_state["owner_frame"]
    assert_match "HTTP 503", @run.last_error
    remove_request_stub(failure)
    Jev::SchedulerWorker.new.perform
    assert_equal 3, @run.discoveries.count
    assert_nil @run.reload.last_error
    assert_requested request, times: 6
  end

  test "known aliases hidden repositories and forks are excluded from owner samples" do
    project = Project.create!(url: "https://github.com/known/current", science_score: 40)
    ProjectRepositoryAlias.create!(project: project, url: "https://github.com/known/previous")
    hidden_owner = Owner.create!(host: Host.find_or_create_by!(name: "GitHub"), login: "blocked", hidden: false)
    Project.create!(url: "https://github.com/known/hidden", owner: hidden_owner, science_score: 1)
    hidden_owner.update!(hidden: true)
    @run.update!(target_count: 2)
    stub_request(:get, %r{#{@host_url}/owners/[^/]+/repositories}).to_return do |request|
      owner = request.uri.path.split('/')[-2]
      { body: ["known/current", "known/previous", "known/hidden", "#{owner}/new"].map { |name| { full_name: name, fork: false } }.push({ full_name: "#{owner}/fork", fork: true }).to_json }
    end
    Jev::SchedulerWorker.new.perform
    assert_equal 2, @run.discoveries.count
    assert @run.discoveries.all? { |candidate| candidate.repository_url.end_with?("/new") }
    assert @run.reload.sampling_complete?
  end

  test "exhausted owner windows finish an underfilled run with visible provenance" do
    @run.update!(settings: @run.settings.merge("owner_windows" => 1))
    stub_request(:get, "#{@host_url}/owners").with(query: hash_including("sort" => "created_at")).to_return(body: [].to_json)
    Jev::SchedulerWorker.new.perform
    assert @run.reload.sampling_complete?
    assert_equal true, @run.sampling_state["frame_exhausted"]
    assert_equal 0, @run.discoveries.count
  end
end
