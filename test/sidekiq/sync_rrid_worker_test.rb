require "test_helper"
require_relative "../support/rrid_pipeline"

class SyncRridWorkerTest < ActiveSupport::TestCase
  include RridPipeline

  setup do
    @project = Project.create!(url: "https://github.com/thelovelab/deseq2", science_score: 42)
    @project.repository_aliases.create!(url: "https://github.com/mikelove/deseq2")
  end

  test "worker resolves canonical IDs through aliases and retains raw funding and provenance without changing projects" do
    request = rrid_record("SCR_015687")
    before = @project.attributes
    assert_no_difference "Project.count" do
      sync_rrid(%w[rrid:scr_015687 SCR_015687])
    end
    record = @project.external_software_records.sole
    assert_equal "rrid", record.source
    assert_equal "SCR_015687", record.identifier
    assert_equal @rrid["SCR_015687"], record.metadata
    assert_equal "ok", record.status
    assert_equal before, @project.reload.attributes
    evidence = @project.project_external_software_records.sole.evidence.sole
    assert_equal "distributions.alternate", evidence["source_field"]
    assert_equal "repository_alias", evidence["match_method"]
    assert_equal "https://scicrunch.org/resolver/SCR_015687", evidence["source_record_url"]
    assert_equal "https://scicrunch.org/resolver/SCR_015687.json", evidence["collection_url"]
    sync_rrid(["SCR_015687"])
    assert_requested request, times: 1
    assert_equal 1, ExternalSoftwareRecord.count
  end

  test "current alternate and Pages URLs deduplicate project links while deprecated and related resources do not match" do
    record = @rrid["SCR_015687"]
    record["distributions"]["current"] = [{ "uri" => @project.url }, { "uri" => "https://mikelove.github.io/DESeq2/docs/" }]
    other = Project.create!(url: "https://github.com/other/tool")
    record["distributions"]["deprecated"] = [{ "uri" => other.url }]
    record["graph"]["related"] = [{ "uri" => other.url }]
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    assert_equal 1, ProjectExternalSoftwareRecord.count
    assert_equal 3, @project.project_external_software_records.sole.evidence.size
    assert_equal 1, @project.project_external_software_records.sole.evidence.count { |e| e["url_transformation"] == "github_pages" }
    assert_empty other.external_software_records
  end

  test "nonsoftware invalid and nonunique resources cannot retain confirmed links" do
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    original = @rrid["SCR_015687"].deep_dup
    [original.merge("recordValid" => false),
      original.merge("rrid" => original["rrid"].merge("is_unique" => "false")),
      original.merge("item" => original["item"].merge("types" => [{ "name" => "database" }]))].each do |record|
      expire_rrid
      rrid_record("SCR_015687", body: rrid_response(record))
      sync_rrid(["SCR_015687"])
      assert_empty ProjectExternalSoftwareRecord.all
    end
    @rrid["SCR_005400"]["distributions"]["current"] = [{ "uri" => @project.url }]
    rrid_record("SCR_005400")
    sync_rrid(["SCR_005400"])
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "generic homepages malformed paths and organization URLs cannot establish identity" do
    urls = ["https://example.org/a/b", "https://github.com/mikelove", "https://github.com/topics/deseq2",
      "https://github.com/mikelove/%2Fsecret", "https://mikelove.github.io", "https://mikelove.github.io/index.html",
      "https://user:pass@github.com/thelovelab/deseq2", "https://github.com:444/thelovelab/deseq2"]
    @rrid["SCR_015687"]["distributions"] = { "current" => urls.map { |url| { "uri" => url } }, "alternate" => [] }
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "ambiguous aliases retain candidates but exclude registry references" do
    other = Project.create!(url: "https://github.com/other/deseq2")
    other.repository_aliases.create!(url: "https://github.com/mikelove/deseq2")
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    assert_equal 2, ProjectExternalSoftwareRecord.count
    assert_equal ["ambiguous"], ProjectExternalSoftwareRecord.distinct.pluck(:match_status)
    assert_empty @project.project_external_software_records.registry_references
  end

  test "confirmed missing records retain raw evidence but hide references" do
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    expire_rrid
    rrid_record("SCR_015687", status: 404, body: { hits: { total: 0, hits: [] }, resolver: { error: "RRID not found" } })
    sync_rrid(["SCR_015687"])
    assert_equal "missing", ExternalSoftwareRecord.sole.status
    assert_equal @rrid["SCR_015687"], ExternalSoftwareRecord.sole.metadata
    assert_equal 1, ProjectExternalSoftwareRecord.count
    assert_empty @project.project_external_software_records.registry_references
  end

  test "malformed wrong identity and incomplete responses preserve prior evidence as errors" do
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    bodies = [{}, { hits: { total: 1, hits: ["invalid"] } }, rrid_response(@rrid["SCR_026162"]),
      rrid_response(@rrid["SCR_015687"].except("distributions")), { hits: { total: 2, hits: [] } }]
    bodies.each do |body|
      expire_rrid
      rrid_record("SCR_015687", body: body)
      assert_raises(RridClient::Error) { sync_rrid(["SCR_015687"]) }
      assert_equal "error", ExternalSoftwareRecord.sole.status
      assert_equal @rrid["SCR_015687"], ExternalSoftwareRecord.sole.metadata
      assert_equal 1, @project.project_external_software_records.registry_references.size
    end
    expire_rrid
    rrid_record("SCR_015687", status: 404, body: { hits: { total: 0, hits: [] }, resolver: "invalid" })
    assert_raises(RridClient::Error) { sync_rrid(["SCR_015687"]) }
  end

  test "rate limits preserve partial batches and share a cooldown with retries" do
    rrid_record("SCR_015687")
    request = rrid_record("SCR_026162", status: 429, headers: { "Retry-After" => "600" })
    sync_rrid(%w[SCR_015687 SCR_026162])
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: "SCR_015687").status
    assert_equal "error", ExternalSoftwareRecord.find_by!(identifier: "SCR_026162").status
    assert SyncRridWorker.jobs.sole["at"] >= 9.minutes.from_now.to_f
    assert_raises(RridClient::RateLimited) { RridClient.new.record("SCR_026162") }
    assert_requested request, times: 1
  end

  test "invalid IDs and oversized batches never make requests" do
    [[], [1], ["SCR_000000"], ["AB_123456"], ["SCR_123"], ["../SCR_015687"], ["SCR_015687"] * 51].each do |ids|
      assert_raises(ArgumentError) { SyncRridWorker.new.perform(ids) }
    end
    assert_not_requested :any, /scicrunch.org/
  end

  test "resolver search results select the unique exact primary RRID rather than an alias hit" do
    response = JSON.parse(Rails.root.join("test/fixtures/files/rrid_resolver_cases.json").read).fetch("SCR_004706")
    rrid_record("SCR_004706", body: response)
    sync_rrid(["SCR_004706"])
    record = ExternalSoftwareRecord.sole
    assert_equal "ok", record.status
    assert_equal "SCR_004706", record.identifier
    assert_equal response["hits"]["hits"].last["_source"], record.metadata
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "extra alias search hits do not prevent exact software matches or allow duplicate exact identities" do
    canonical = @rrid.fetch("SCR_015687")
    other = @rrid.fetch("SCR_026162")
    body = { hits: { total: 2, hits: [{ _source: other }, { _source: canonical }] } }
    rrid_record("SCR_015687", body: body)
    sync_rrid(["SCR_015687"])
    assert_equal "SCR_015687", @project.external_software_records.sole.identifier
    expire_rrid
    body[:hits][:hits] = [{ _source: canonical }, { _source: canonical }]
    rrid_record("SCR_015687", body: body)
    error = assert_raises(RridClient::Error) { sync_rrid(["SCR_015687"]) }
    assert_equal "Expected one exact RRID record for SCR_015687, got 2", error.message
    assert_equal canonical, @project.external_software_records.sole.metadata
    assert_equal 1, @project.project_external_software_records.registry_references.size
  end

  test "live resolver redirect fixture resolves an explicitly declared nonsoftware alias" do
    response = JSON.parse(Rails.root.join("test/fixtures/files/rrid_resolver_cases.json").read).fetch("SCR_004630")
    rrid_record("SCR_016578", status: 302, body: {}, headers: { "Location" => "/resolver/SCR_004630.json" })
    rrid_record("SCR_004630", body: response)
    sync_rrid(["SCR_016578"])
    assert_equal %w[SCR_004630 SCR_016578], ExternalSoftwareRecord.order(:identifier).pluck(:identifier)
    assert_equal ["ok"], ExternalSoftwareRecord.distinct.pluck(:status)
    assert_empty ProjectExternalSoftwareRecord.all
    alias_record = ExternalSoftwareRecord.find_by!(identifier: "SCR_016578")
    assert_nil alias_record.next_discovery_at
    assert_equal "SCR_004630", alias_record.metadata.dig("item", "identifier")
    assert_equal "https://scicrunch.org/resolver/SCR_004630.json", alias_record.collection_url
  end

  test "verified software aliases refresh once and only canonical records attach to projects" do
    @rrid["SCR_015687"]["item"]["alternateIdentifiers"] = [{ "identifier" => "SCR_016578" }]
    redirect = rrid_record("SCR_016578", status: 302, body: {}, headers: { "Location" => "/resolver/SCR_015687.json" })
    rrid_record("SCR_015687")
    stale_alias = ExternalSoftwareRecord.create!(source: "rrid", identifier: "SCR_016578", next_refresh_at: 1.day.ago)
    @project.project_external_software_records.create!(external_software_record: stale_alias,
      relationship: "source_code_repository", match_status: "matched")
    before = @project.attributes
    sync_rrid(%w[SCR_016578 SCR_015687])
    assert_equal "SCR_015687", @project.external_software_records.sole.identifier
    assert_equal @rrid["SCR_015687"], stale_alias.reload.metadata
    assert_equal 1, @project.project_external_software_records.registry_references.size
    assert_equal [["rrid", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
    assert_equal before, @project.reload.attributes
    sync_rrid(["SCR_016578"])
    assert_requested redirect, times: 1
  end

  test "redirects cannot change host protocol identity or accept an undeclared alias" do
    locations = ["https://example.org/resolver/SCR_015687.json", "http://scicrunch.org/resolver/SCR_015687.json",
      "https://scicrunch.org/resolver/SCR_015687.json?secret=x", "/resolver/SCR_000000.json", "/resolver/SCR_016578.json"]
    locations.each do |location|
      expire_rrid
      rrid_record("SCR_016578", status: 302, body: {}, headers: { "Location" => location })
      error = assert_raises(RridClient::Error) { sync_rrid(["SCR_016578"]) }
      assert_includes error.message, "SCR_016578"
    end
    expire_rrid
    rrid_record("SCR_016578", status: 302, body: {}, headers: { "Location" => "/resolver/SCR_015687.json" })
    rrid_record("SCR_015687")
    error = assert_raises(RridClient::Error) { sync_rrid(["SCR_016578"]) }
    assert_equal "Unverified RRID redirect from SCR_016578 to SCR_015687", error.message
    assert_empty ProjectExternalSoftwareRecord.all
    assert_not_requested :any, /example.org/
  end

  test "a malformed record does not prevent later valid records in the batch from being saved" do
    rrid_record("SCR_026162", body: {})
    rrid_record("SCR_015687")
    error = assert_raises(RridClient::Error) { sync_rrid(%w[SCR_026162 SCR_015687]) }
    assert_equal "Invalid RRID response for SCR_026162", error.message
    assert_equal "error", ExternalSoftwareRecord.find_by!(identifier: "SCR_026162").status
    assert_equal "ok", @project.external_software_records.sole.status
    assert_equal "SCR_015687", @project.external_software_records.sole.identifier
  end

  test "canonical import and alias completion roll back together" do
    @rrid["SCR_015687"]["item"]["alternateIdentifiers"] = [{ "identifier" => "SCR_016578" }]
    rrid_record("SCR_016578", status: 302, body: {}, headers: { "Location" => "/resolver/SCR_015687.json" })
    rrid_record("SCR_015687")
    RridImporter.any_instance.stubs(:persist_alias).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { sync_rrid(["SCR_016578"]) }
    assert_empty ExternalSoftwareRecord.all
    assert_empty ProjectExternalSoftwareRecord.all
  end
end
