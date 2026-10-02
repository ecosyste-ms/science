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
end
