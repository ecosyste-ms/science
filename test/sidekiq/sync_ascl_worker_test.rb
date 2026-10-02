require "test_helper"
require_relative "../support/ascl_pipeline"

class SyncAsclWorkerTest < ActiveSupport::TestCase
  include AsclPipeline

  setup do
    @project = Project.create!(url: "https://github.com/astropy/photutils", science_score: 42)
  end

  test "worker caches published records and retains raw ASCL metadata and indexed matches" do
    request = ascl_catalogue
    before = @project.attributes
    sync_ascl(%w[1609.011 1609.011])
    record = @project.external_software_records.sole
    assert_equal "ascl", record.source
    assert_equal "1609.011", record.identifier
    assert_equal "https://ascl.net/1609.011", record.record_url
    assert_equal @ascl["1609.011"], record.metadata
    assert_equal "ok", record.status
    evidence = @project.project_external_software_records.sole.evidence.sole
    assert_equal "site_list", evidence["source_field"]
    assert_equal AsclClient::CATALOGUE_URL, evidence["collection_url"]
    assert_equal before, @project.reload.attributes
    sync_ascl(["1010.083"])
    sync_ascl(["1609.011"])
    assert_requested request, times: 1
    assert_equal 2, ExternalSoftwareRecord.count
  end

  test "site lists distinguish repository URLs from documentation homepages and publication links" do
    @ascl["1609.011"]["site_list"] = ["https://photutils.readthedocs.io/en/latest/",
      "https://doi.org/10.5281/zenodo.596036", "https://www.astropy.org/photutils/download",
      "https://github.com/topics/photometry", "https://github.com/astropy", "https://github.com:8080/astropy/photutils",
      "https://secret@github.com/astropy/photutils", "https://github.com.evil.example/astropy/photutils"]
    @ascl["1609.011"]["preferred_citation"] = @project.url
    ascl_catalogue
    sync_ascl(["1609.011"])
    assert_empty ProjectExternalSoftwareRecord.all
    assert_equal "ok", ExternalSoftwareRecord.sole.status
  end

  test "GitHub Pages project URLs retain the original URL and resolve through repository aliases" do
    @project.repository_aliases.create!(url: "https://github.com/astropy/old-photutils")
    pages_url = "https://Astropy.github.io/old-photutils/docs/index.html?version=stable#section"
    @ascl["1609.011"]["site_list"] = [pages_url, @project.url]
    ascl_catalogue
    sync_ascl(["1609.011"])
    assert_equal 1, ProjectExternalSoftwareRecord.count
    evidence = @project.project_external_software_records.sole.evidence.find { |entry| entry["url_transformation"] }
    assert_equal pages_url, evidence["source_url"]
    assert_equal "github_pages", evidence["url_transformation"]
    assert_equal "repository_alias", evidence["match_method"]
    assert_equal pages_url, evidence["repository_url"]
    assert_equal "https://github.com/astropy/old-photutils", evidence["normalized_url"]
  end

  test "GitHub Pages roots individual files and misleading hostnames do not establish repository identity" do
    @ascl["1609.011"]["site_list"] = ["https://astropy.github.io/", "https://astropy.github.io/photutils.html",
      "https://astropy.github.io.evil.example/photutils", "https://evil.example/astropy.github.io/photutils",
      "https://secret@astropy.github.io/photutils", "https://astropy.github.io/../photutils"]
    ascl_catalogue
    sync_ascl(["1609.011"])
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "GitLab nested groups ambiguity and repeated source references retain their evidence" do
    Host.create!(name: "gitlab.mpcdf.mpg.de", url: "https://gitlab.mpcdf.mpg.de", kind: "GitLab")
    gitlab = Project.create!(url: "https://gitlab.mpcdf.mpg.de/vrs/gadget4")
    other = Project.create!(url: "https://github.com/another/photutils")
    [@project, other].each { |project| project.repository_aliases.create!(url: "https://github.com/former/photutils") }
    @ascl["1609.011"]["site_list"] = ["https://github.com/former/photutils", @project.url]
    ascl_catalogue
    sync_ascl(%w[1609.011 2204.014])
    assert_equal ["ambiguous"], ExternalSoftwareRecord.find_by!(identifier: "1609.011").project_external_software_records.distinct.pluck(:match_status)
    assert_equal "2204.014", gitlab.external_software_records.sole.identifier
    assert_equal 3, ProjectExternalSoftwareRecord.count
  end

  test "incomplete catalogues fail without replacing previously saved metadata or matches" do
    ascl_catalogue
    sync_ascl(["1609.011"])
    before = ExternalSoftwareRecord.sole.attributes
    expire_ascl
    ascl_catalogue(@ascl.values.reject { |record| record["ascl_id"] == "1609.011" },
      index: @ascl.keys.map { |id| { "ascl_id" => id } })
    assert_raises(AsclClient::Error) { sync_ascl(["1609.011"]) }
    record = ExternalSoftwareRecord.sole
    assert_equal "error", record.status
    assert_equal before["metadata"], record.metadata
    assert_equal before["retrieved_at"], record.retrieved_at
    assert_equal 1, @project.project_external_software_records.registry_references.size
    assert_nil Rails.cache.read(AsclClient::CACHE_KEY)
  end

  test "missing records preserve previous evidence while successful refresh removes withdrawn repository links" do
    ascl_catalogue
    sync_ascl(["1609.011"])
    metadata = ExternalSoftwareRecord.sole.metadata
    expire_ascl
    ascl_catalogue(@ascl.values.reject { |record| record["ascl_id"] == "1609.011" })
    sync_ascl(["1609.011"])
    assert_equal "missing", ExternalSoftwareRecord.sole.status
    assert_equal metadata, ExternalSoftwareRecord.sole.metadata
    assert_empty @project.project_external_software_records.registry_references
    expire_ascl
    @ascl["1609.011"]["site_list"] = false
    ascl_catalogue
    sync_ascl(["1609.011"])
    assert_equal "ok", ExternalSoftwareRecord.sole.status
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "rate limits share a cooldown and defer workers" do
    request = ascl_catalogue(status: 429, headers: { "Retry-After" => "600" })
    sync_ascl(["1609.011"])
    assert_equal "error", ExternalSoftwareRecord.sole.status
    assert_equal 1, SyncAsclWorker.jobs.size
    assert SyncAsclWorker.jobs.first["at"] >= 9.minutes.from_now.to_f
    assert_raises(AsclClient::RateLimited) { AsclClient.new.catalogue }
    assert_requested request, times: 1
  end

  test "malformed empty duplicate and unpublished exports are rejected before persistence" do
    [{}, { "1" => @ascl["1609.011"], "2" => @ascl["1609.011"] },
      { "1" => @ascl["1609.011"].merge("ascl_id" => "0000.000") },
      { "1" => @ascl["1609.011"].except("site_list") }].each do |body|
      stub_request(:get, AsclClient::CATALOGUE_URL).to_return(body: body.to_json)
      assert_raises(AsclClient::Error) { SyncAsclWorker.new.perform(["1609.011"]) }
      assert_empty ProjectExternalSoftwareRecord.all
      ExternalSoftwareRecord.delete_all
    end
    [[], ["0000.000"], ["1613.001"], ["1609.000"], ["../1609.011"], ["1609.011"] * 51].each do |ids|
      assert_raises(ArgumentError) { SyncAsclWorker.new.perform(ids) }
    end
  end
end
