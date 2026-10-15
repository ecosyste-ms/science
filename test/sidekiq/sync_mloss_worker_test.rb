require "test_helper"
require_relative "../support/mloss_pipeline"

class SyncMlossWorkerTest < ActiveSupport::TestCase
  include MlossPipeline

  setup do
    @project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator", science_score: 42)
  end

  test "worker matches aliases and multiple labelled repositories without following other links" do
    @project.repository_aliases.create!(url: "https://github.com/old/neuraloperator")
    other = Project.create!(url: "https://gitlab.com/group/nested/software")
    @mloss_html.sub!(@project.url, "https://github.com/old/neuraloperator")
    @mloss_html.sub!("</dd>", '<a href="https://gitlab.com/group/nested/software">code</a><a href="https://github.com/JmlrOrg/v27/tree/main/26-0434">edit</a></dd>')
    request = mloss_catalogue
    before = @project.attributes
    SyncMlossWorker.perform_async(["v27/26-0434"])
    SyncMlossWorker.perform_one
    record = ExternalSoftwareRecord.sole
    assert_equal [@project.id, other.id].sort, record.projects.pluck(:id).sort
    evidence = @project.project_external_software_records.sole.evidence.sole
    assert_equal "repository_alias", evidence["match_method"]
    assert_equal "code_urls", evidence["source_field"]
    assert_equal MlossClient.article_url(record.identifier), evidence["article_url"]
    assert_equal 2, record.metadata["code_urls"].size
    assert_equal before, @project.reload.attributes
    SyncMlossWorker.new.perform(["v27/26-0434"])
    assert_requested request, times: 1
  end

  test "ambiguous repository aliases retain candidates without confirmed matches" do
    other = Project.create!(url: "https://github.com/other/neuraloperator")
    [@project, other].each { |project| project.repository_aliases.create!(url: "https://github.com/old/neuraloperator") }
    @mloss_html.sub!(@project.url, "https://github.com/old/neuraloperator")
    mloss_catalogue
    SyncMlossWorker.new.perform(["v27/26-0434"])
    assert_equal %w[ambiguous ambiguous], ProjectExternalSoftwareRecord.pluck(:match_status)
    assert_empty @project.project_external_software_records.registry_references
    result = DiscoverExternalRepositoriesWorker.new.perform(10)
    assert_equal 1, result[:sources]["mloss"]["ambiguous"]
    assert_empty ExternalProjectSync.all
  end

  test "unsupported unsafe and owner-only code links are retained without repository matches" do
    links = ["https://github.com/neuraloperator", "https://github.com/topics/science",
      "https://secret@github.com/neuraloperator/neuraloperator", "https://github.com:8080/neuraloperator/neuraloperator",
      "https://github.com.evil.example/neuraloperator/neuraloperator", "https://cran.r-project.org/package=example",
      "https://neuraloperator.github.io/neuraloperator/", "https://example.org/software/",
      "https://github.com/neuraloperator/neuraloperator/../../other"]
    @mloss_html.sub!(@project.url, links.first)
    @mloss_html.sub!("</dd>", links.drop(1).map { |url| "<a href=\"#{url}\">code</a>" }.join + "</dd>")
    mloss_catalogue
    SyncMlossWorker.new.perform(["v27/26-0434"])
    assert_equal links, ExternalSoftwareRecord.sole.metadata["code_urls"]
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "refresh removes changed links and saved older pages cannot restore them" do
    mloss_catalogue
    SyncMlossWorker.new.perform(["v27/26-0434"])
    record = ExternalSoftwareRecord.sole
    older = record.metadata.deep_dup
    old_time = record.retrieved_at
    travel 1.minute do
      expire_mloss
      @mloss_html.sub!(@project.url, "https://example.org/neuraloperator")
      mloss_catalogue
      SyncMlossWorker.new.perform(["v27/26-0434"])
    end
    assert_empty ProjectExternalSoftwareRecord.all
    MlossImporter.new.sync_page([older], started_at: old_time)
    assert_empty ProjectExternalSoftwareRecord.all
    assert_equal ["https://example.org/neuraloperator"], record.reload.metadata["code_urls"]
  end

  test "absent records and malformed catalogues preserve previous metadata and evidence" do
    mloss_catalogue
    SyncMlossWorker.new.perform(["v27/26-0434"])
    metadata = ExternalSoftwareRecord.sole.metadata
    bad_pages = ["<html>Unavailable</html>", @mloss_html.sub("26-0434.html", "25-2553.html"),
      @mloss_html.sub("/papers/v27/26-0434.html", "https://example.org/papers/v27/26-0434.html"),
      @mloss_html.sub("A Library for Learning Neural Operators", ""),
      @mloss_html.sub('<a href="https://github.com/neuraloperator/neuraloperator">code</a>', "")]
    doc = Nokogiri::HTML(@mloss_html)
    doc.css("dl").first.remove
    bad_pages << doc.to_html
    bad_pages.each do |body|
      expire_mloss
      mloss_catalogue(body: body)
      assert_raises(MlossClient::Error) { SyncMlossWorker.new.perform(["v27/26-0434"]) }
      record = ExternalSoftwareRecord.sole
      assert_equal metadata, record.metadata
      assert_equal "error", record.status
      assert_equal 1, @project.project_external_software_records.registry_references.size
    end
  end

  test "rate-limited manual sync schedules another attempt and keeps a shared cooldown" do
    request = mloss_catalogue(status: 503, headers: { "Retry-After" => "600" })
    SyncMlossWorker.new.perform(["v27/26-0434"])
    assert_equal "error", ExternalSoftwareRecord.sole.status
    assert_equal 1, SyncMlossWorker.jobs.size
    assert SyncMlossWorker.jobs.first["at"] >= 9.minutes.from_now.to_f
    assert_raises(MlossClient::RateLimited) { MlossClient.new.catalogue }
    assert_requested request, times: 1
  end
end
