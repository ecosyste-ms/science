require "test_helper"

class Api::V1::ProjectExternalIdentifiersTest < ActionDispatch::IntegrationTest
  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @project = Project.create!(url: "https://github.com/sympy/sympy")
  end

  test "returns persisted worker evidence without writes requests or jobs" do
    payload = JSON.parse(File.read(Rails.root.join("test/fixtures/files/wikidata.json")))
    stub_request(:get, WikidataClient::API_URL)
      .with(query: hash_including(ids: "Q5971368")).to_return(body: payload.to_json)
    SyncWikidataWorker.new.perform(["Q5971368"])
    before = @project.reload.attributes
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!

    get "/api/v1/projects/#{@project.id}/external_identifiers"

    assert_response :success
    body = response.parsed_body.sole
    assert_equal "wikidata", body["scheme"]
    assert_equal "Q5971368", body["identifier"]
    assert_equal "matched", body["match_status"]
    assert_equal "ok", body["source_status"]
    assert_equal payload["entities"]["Q5971368"], body["metadata"]
    assert body["retrieved_at"]
    assert_equal before, @project.reload.attributes
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /wikidata.org/
  end

  test "empty unchecked projects and hidden projects have distinct responses" do
    get "/api/v1/projects/#{@project.id}/external_identifiers"
    assert_response :success
    assert_equal [], response.parsed_body
    owner = Owner.create!(host: Host.create!(name: "Wikidata API Host"), login: "hidden", hidden: true)
    @project.update_columns(owner_id: owner.id)
    get "/api/v1/projects/#{@project.id}/external_identifiers"
    assert_response :not_found
  end

  test "paginates cached records" do
    3.times do |index|
      record = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q#{index + 1}", next_refresh_at: Time.current)
      @project.project_external_software_records.create!(external_software_record: record,
        relationship: "source_code_repository", match_status: "matched")
    end
    get "/api/v1/projects/#{@project.id}/external_identifiers", params: { per_page: 2 }
    assert_response :success
    assert_equal %w[Q1 Q2], response.parsed_body.pluck("identifier")
    get "/api/v1/projects/#{@project.id}/external_identifiers", params: { per_page: 2, page: 2 }
    assert_response :success
    assert_equal ["Q3"], response.parsed_body.pluck("identifier")
  end
end
