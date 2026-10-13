require "test_helper"
require "rake"

class HuggingFaceDiscoveryTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:import_huggingface")
    @previous_limit = ENV.delete("MAX_PAGES")
    @registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co",
      ecosystem: "huggingface", purl_type: "huggingface")
  end

  teardown do
    ENV["MAX_PAGES"] = @previous_limit
  end

  def import
    Rake::Task["projects:import_huggingface"].reenable
    capture_io { Rake::Task["projects:import_huggingface"].invoke }.first
  end

  def record(name, topics, id:)
    { "id" => id, "name" => "lab/#{name}", "purl" => "pkg:huggingface/lab/#{name}",
      "keywords_array" => topics, "repository_url" => nil, "latest_release_number" => "a" * 40,
      "description" => "An encoder for scientific documents.", "downloads" => 100 }
  end

  test "discovery requires a paper topic and imports repeatable package project identities" do
    rows = [record("accepted", ["arxiv:1810.04805"], id: 101),
      record("doi", ["doi:10.1234/example"], id: 102),
      record("no-paper", ["transformers", "research"], id: 103),
      record("empty-reference", ["arxiv:"], id: 104),
      record("disabled", ["arxiv:1810.04805"], id: 105).merge("status" => "removed")]
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/registries/huggingface.co/packages?page=1")
      .to_return(status: 200, body: rows.to_json)
    SyncProjectWorker.expects(:perform_async).twice

    assert_difference ["Project.count", "Package.count"], 2 do
      assert_no_difference ["Paper.count", "Mention.count", "PackagePaper.count", "PackageProject.count"] do
        assert_includes import, "Total new projects created: 2"
      end
    end
    package = @registry.packages.find_by!(name: "lab/accepted")
    project = package.published_by_project
    assert_equal "https://huggingface.co/lab/accepted", project.url
    assert_equal "lab/accepted", project.name
    assert_equal ["arxiv:1810.04805"], project.keywords
    assert_nil package.repository_url
    Project.where(id: @registry.packages.select(:published_by_project_id)).update_all(last_synced_at: Time.current)
    assert_no_difference ["Project.count", "Package.count"] do
      assert_includes import, "Total existing projects found: 2"
    end
    assert_not_requested :get, /page=2/
  end

  test "discovery validates its page bound before requests" do
    ENV["MAX_PAGES"] = "0"
    assert_raises(ArgumentError) { import }
    assert_not_requested :any, /.*/
  end
end
