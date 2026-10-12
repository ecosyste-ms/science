require "test_helper"
require "rake"
require "tempfile"

class HuggingFacePackageImportTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:import_huggingface")
    @original_env = %w[FILE DRY_RUN].to_h { |key| [key, ENV[key]] }
    @file = Tempfile.new(["hugging-face-purls", ".json"])
    ENV["FILE"] = @file.path
    ENV.delete("DRY_RUN")
    @registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co",
      ecosystem: "huggingface", purl_type: "huggingface")
    @purl = "pkg:huggingface/google-bert/bert-base-uncased"
    @record = { "id" => 15576184, "name" => "google-bert/bert-base-uncased", "namespace" => "google-bert",
      "purl" => @purl, "repository_url" => nil, "updated_at" => "2026-10-12T00:03:37Z",
      "latest_release_number" => "86b5e0934494bd15c9632b12f734a8a67f723594",
      "metadata" => { "card_data" => { "license" => "apache-2.0" } },
      "keywords" => ["arxiv:1810.04805"], "registry" => { "name" => "huggingface.co" } }
  end

  teardown do
    @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    @file.close!
  end

  def run_import(purls, apply: false)
    File.write(@file.path, purls.to_json)
    ENV["DRY_RUN"] = apply ? "false" : "true"
    invoke_task
  end

  def invoke_task
    Rake::Task["packages:import_huggingface"].reenable
    output, = capture_io { Rake::Task["packages:import_huggingface"].invoke }
    JSON.parse(output)
  end

  def lookup(purl = @purl, records: [@record], status: 200)
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .with(query: { purl: purl }).to_return(status: status, body: records.to_json)
  end

  test "defaults to a dry run through the public task without writes or jobs" do
    File.write(@file.path, [@purl].to_json)
    request = lookup
    jobs = Sidekiq::Worker.jobs.deep_dup

    assert_no_difference ["Package.count", "Project.count", "Paper.count", "PackagePaper.count", "PackageProject.count", "Mention.count"] do
      report = invoke_task
      assert_equal true, report.fetch("dry_run")
      assert_equal({ "would_create" => 1 }, report.fetch("counts"))
      assert_equal @purl, report.fetch("packages").sole.fetch("purl")
    end
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_requested request, times: 1
  end

  test "imports a model without a repository and retains the raw Packages response" do
    request = lookup
    jobs = Sidekiq::Worker.jobs.deep_dup
    assert_difference "Package.count", 1 do
      assert_no_difference ["Project.count", "Paper.count", "PackagePaper.count", "PackageProject.count", "Mention.count"] do
        report = run_import([@purl], apply: true)
        assert_equal({ "created" => 1 }, report.fetch("counts"))
      end
    end
    package = Package.find_by!(purl: @purl)
    assert_equal @registry, package.package_registry
    assert_equal @record, package.metadata
    assert_equal 15576184, package.ecosystems_id
    assert_equal "google-bert", package.namespace
    assert_equal "matched", package.ecosystems_sync_status
    assert package.ecosystems_checked_at
    assert_nil package.repository_url
    assert_nil package.published_by_project_id
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_requested request, times: 1
  end

  test "normalizes versions and subpaths and deduplicates before lookup" do
    request = lookup
    report = run_import([@purl, "pkg:HuggingFace/google-bert/bert-base-uncased@abcdef#README.md"], apply: true)
    assert_equal 2, report.fetch("input_count")
    assert_equal 1, report.fetch("selected")
    assert_equal({ "created" => 1 }, report.fetch("counts"))
    assert_equal @purl, Package.sole.purl
    assert_requested request, times: 1
  end

  test "reuses existing packages without metadata refresh or relationship changes" do
    lookup
    run_import([@purl], apply: true)
    package = Package.find_by!(purl: @purl)
    project = Project.create!(url: "https://github.com/example/model")
    evidence = [{ "source" => "review", "url" => project.url }]
    link = PackageProject.create!(package: package, project: project, role: "model_implementation", evidence: evidence)
    package.update!(published_by_project: project)
    original = package.reload.attributes
    original_link = link.attributes
    WebMock.reset!
    jobs = Sidekiq::Worker.jobs.deep_dup

    [false, true].each do |apply|
      report = run_import([@purl], apply: apply)
      assert_equal({ "existing" => 1 }, report.fetch("counts"))
      assert_equal original, package.reload.attributes
      assert_equal original_link, link.reload.attributes
    end
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /.*/
  end

  test "reports missing packages as retry candidates without creating placeholders" do
    lookup(records: [])
    assert_no_difference "Package.count" do
      row = run_import([@purl], apply: true).fetch("packages").sole
      assert_equal "missing", row.fetch("status")
      assert_equal true, row.fetch("retryable")
      assert_equal @purl, row.fetch("purl")
    end
    lookup
    assert_equal({ "created" => 1 }, run_import([@purl], apply: true).fetch("counts"))
  end

  test "reports lookup errors and continues the bounded batch" do
    lookup(status: 503)
    other_purl = "pkg:huggingface/ProsusAI/finbert"
    other = @record.merge("id" => 15576185, "purl" => other_purl, "name" => "ProsusAI/finbert", "namespace" => "ProsusAI")
    lookup(other_purl, records: [other])
    report = run_import([@purl, other_purl], apply: true)
    assert_equal({ "error" => 1, "created" => 1 }, report.fetch("counts"))
    assert_equal true, report.fetch("packages").first.fetch("retryable")
    assert_equal other_purl, Package.sole.purl
  end

  test "rejects ambiguous malformed and mismatched responses without writes" do
    responses = [[@record, @record], [nil], [@record.merge("id" => nil)],
      [@record.merge("purl" => "pkg:pypi/bert")], [@record.merge("name" => "other/model")],
      [@record.merge("registry" => { "name" => "other.example" })]]
    responses.each_with_index do |records, index|
      lookup(records: records)
      assert_no_difference "Package.count" do
        row = run_import([@purl], apply: true).fetch("packages").sole
        assert_equal(index.zero? ? "ambiguous" : "conflict", row.fetch("status"))
        assert_equal false, row.fetch("retryable")
      end
    end
  end

  test "does not overwrite a name collision or an upstream ID owned by another package" do
    existing = Package.create!(package_registry: @registry, name: @record.fetch("name"))
    lookup
    assert_equal "conflict", run_import([@purl], apply: true).fetch("packages").sole.fetch("status")
    assert_nil existing.reload.purl
    existing.update!(name: "other/model", purl: "pkg:huggingface/other/model", ecosystems_id: @record.fetch("id"))
    original = existing.reload.attributes
    assert_equal "conflict", run_import([@purl], apply: true).fetch("packages").sole.fetch("status")
    assert_equal original, existing.reload.attributes
    assert_equal 1, Package.count
  end

  test "validates the entire input and bound before any lookup or import" do
    invalid_inputs = [[], nil, {}, [@purl, nil], [@purl, "pkg:pypi/numpy"],
      ["#{@purl}?repository_url=https://other.example"], ["pkg:huggingface/model"],
      ["pkg:huggingface/owner/nested/model"], Array.new(501, @purl)]
    invalid_inputs.each do |input|
      assert_no_difference "Package.count" do
        assert_raises(ArgumentError) { run_import(input, apply: true) }
      end
    end
    assert_not_requested :any, /.*/
  end

  test "requires a synced registry and rejects unsafe task inputs before requests" do
    @registry.destroy!
    assert_raises(ArgumentError) { run_import([@purl], apply: true) }
    File.write(@file.path, [@purl].to_json)
    ENV["DRY_RUN"] = "flase"
    assert_raises(ArgumentError) { invoke_task }
    ENV["DRY_RUN"] = "true"
    File.write(@file.path, " " * (1.megabyte + 1))
    assert_raises(ArgumentError) { invoke_task }
    File.write(@file.path, "invalid JSON")
    assert_raises(JSON::ParserError) { invoke_task }
    assert_not_requested :any, /.*/
  end
end
