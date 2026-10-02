require "test_helper"
require_relative "../support/swmath_pipeline"

class SyncSwmathWorkerTest < ActiveSupport::TestCase
  include SwmathPipeline

  setup { @project = Project.create!(url: "https://github.com/numpy/numpy", science_score: 42) }

  test "worker stores raw metadata and source attribution without changing scores or fetching fresh records" do
    request = swmath_record("6294")
    before = @project.attributes
    sync_swmath(%w[6294 6294])
    record = @project.external_software_records.sole
    assert_equal "swmath", record.source
    assert_equal "6294", record.identifier
    assert_equal "https://zbmath.org/software/6294", record.record_url
    assert_equal @swmath["6294"], record.metadata
    assert_equal "ok", record.status
    assert_equal before, @project.reload.attributes
    evidence = @project.project_external_software_records.sole.evidence.sole
    assert_equal "source_code", evidence["source_field"]
    assert_equal SwmathClient::API_URL, evidence["collection_url"]
    assert_equal "CC-BY-SA-4.0", evidence["source_license"]
    sync_swmath(["6294"])
    assert_requested request, times: 1
    assert_equal 1, ExternalSoftwareRecord.count
  end

  test "absent repositories organisation URLs and homepage fields do not establish matches" do
    scipy = Project.create!(url: "https://github.com/scipy/scipy")
    sympy = Project.create!(url: "https://github.com/sympy/sympy")
    %w[6293 940 4314].each { |id| swmath_record(id) }
    sync_swmath(%w[6293 940 4314])
    assert_empty scipy.external_software_records
    assert_empty sympy.external_software_records
    assert_empty ProjectExternalSoftwareRecord.all
    assert_equal 3, ExternalSoftwareRecord.count
    expire_swmath
    @swmath["6294"]["source_code"] = nil
    @swmath["6294"]["homepage"] = @project.url
    swmath_record("6294")
    sync_swmath(["6294"])
    assert_empty @project.external_software_records
  end

  test "Pages conversion uses aliases and keeps original provenance" do
    @project.repository_aliases.create!(url: "https://github.com/numpy/old")
    url = "https://NumPy.github.io/old/docs/index.html"
    @swmath["6294"]["source_code"] = url
    swmath_record("6294")
    sync_swmath(["6294"])
    evidence = @project.project_external_software_records.sole.evidence.sole
    assert_equal url, evidence["source_url"]
    assert_equal "github_pages", evidence["url_transformation"]
    assert_equal "repository_alias", evidence["match_method"]
  end

  test "ambiguous aliases retain every candidate and several source records can describe one repository" do
    other = Project.create!(url: "https://github.com/another/numpy")
    [@project, other].each { |project| project.repository_aliases.create!(url: "https://github.com/former/numpy") }
    @swmath["6294"]["source_code"] = "https://github.com/former/numpy"
    @swmath["825"]["source_code"] = @project.url
    %w[6294 825].each { |id| swmath_record(id) }
    sync_swmath(%w[6294 825])
    assert_equal ["ambiguous"], ExternalSoftwareRecord.find_by!(identifier: "6294").project_external_software_records.distinct.pluck(:match_status)
    assert_equal 3, ProjectExternalSoftwareRecord.count
    assert_equal ["825"], @project.project_external_software_records.registry_references.pluck(:identifier)
  end

  test "an explicit missing response preserves evidence and a later withdrawal removes links" do
    swmath_record("6294")
    sync_swmath(["6294"])
    metadata = ExternalSoftwareRecord.sole.metadata
    expire_swmath
    swmath_record("6294", body: swmath_missing)
    sync_swmath(["6294"])
    assert_equal "missing", ExternalSoftwareRecord.sole.status
    assert_equal metadata, ExternalSoftwareRecord.sole.metadata
    assert_empty @project.project_external_software_records.registry_references
    expire_swmath
    @swmath["6294"]["source_code"] = nil
    swmath_record("6294")
    sync_swmath(["6294"])
    assert_equal "ok", ExternalSoftwareRecord.sole.status
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "malformed wrong-ID and generic missing responses preserve prior records as failures" do
    swmath_record("6294")
    sync_swmath(["6294"])
    before = ExternalSoftwareRecord.sole.metadata
    [{}, { "result" => nil, "status" => {} }, swmath_response(@swmath["825"]),
      swmath_response(@swmath["6294"].except("source_code")), swmath_missing(code: 404)].each do |body|
      expire_swmath
      swmath_record("6294", body: body)
      assert_raises(SwmathClient::Error) { sync_swmath(["6294"]) }
      assert_equal "error", ExternalSoftwareRecord.sole.status
      assert_equal before, ExternalSoftwareRecord.sole.metadata
      assert_equal 1, @project.project_external_software_records.registry_references.size
    end
  end

  test "rate limits defer jobs share a cooldown and retain successfully fetched records" do
    swmath_record("6294")
    request = swmath_record("825", status: 429, headers: { "Retry-After" => "600" })
    sync_swmath(%w[6294 825])
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: "6294").status
    assert_equal "error", ExternalSoftwareRecord.find_by!(identifier: "825").status
    assert SyncSwmathWorker.jobs.sole["at"] >= 9.minutes.from_now.to_f
    assert_raises(SwmathClient::RateLimited) { SwmathClient.new.record("825") }
    assert_requested request, times: 1
  end

  test "invalid and oversized batches are rejected before requests" do
    [[], [0], ["0"], ["01"], ["../2"], ["1.2"], ["1"] * 51].each do |ids|
      assert_raises(ArgumentError) { SyncSwmathWorker.new.perform(ids) }
    end
    assert_not_requested :any, /api.zbmath.org/
  end
end
