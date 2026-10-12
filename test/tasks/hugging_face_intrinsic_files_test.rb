require "test_helper"
require "rake"
require "tempfile"

class HuggingFaceIntrinsicFilesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:collect_huggingface")
    @original_file = ENV["FILE"]
    @file = Tempfile.new(["model-versions", ".json"])
    ENV["FILE"] = @file.path
    @revision = "86b5e0934494bd15c9632b12f734a8a67f723594"
    registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co",
      ecosystem: "huggingface", purl_type: "huggingface")
    @package = registry.packages.create!(name: "google-bert/bert-base-uncased",
      purl: "pkg:huggingface/google-bert/bert-base-uncased", ecosystems_id: 15576184)
    @version = @package.package_versions.create!(number: @revision, purl: "#{@package.purl}@#{@revision}",
      ecosystems_id: 245802722, fetched_at: Time.current)
    @metadata_url = "https://huggingface.co/api/models/#{@package.name}/revision/#{@revision}"
    @base_url = "https://huggingface.co/#{@package.name}/resolve/#{@revision}"
  end

  teardown do
    @original_file.nil? ? ENV.delete("FILE") : ENV["FILE"] = @original_file
    @file.close!
  end

  def collect(purls = [@version.purl])
    File.write(@file.path, purls.to_json)
    invoke
  end

  def invoke
    Rake::Task["packages:collect_huggingface"].reenable
    output, = capture_io { Rake::Task["packages:collect_huggingface"].invoke }
    JSON.parse(output)
  end

  def metadata(paths, revision: @revision)
    stub_request(:get, @metadata_url).to_return(body: {
      id: @package.name, sha: revision, siblings: paths.map { |path| { rfilename: path } }
    }.to_json)
  end

  def file(path, body: "text", status: 200, headers: {})
    stub_request(:get, "#{@base_url}/#{path}").to_return(status: status, body: body, headers: headers)
  end

  test "task collects pinned text with provenance without changing packages or relationships" do
    metadata_request = metadata(%w[README.md CITATION.bib model.safetensors pytorch_model.bin ../config.json docs/README.md README.md])
    readme = "# BERT\n```bibtex\n@article{bert, title={BERT}}\n```\n"
    readme_request = file("README.md", body: readme)
    citation_request = file("CITATION.bib", body: "@article{bert, title={BERT}}")
    original_package = @package.attributes
    original_version = @version.attributes
    jobs = Sidekiq::Worker.jobs.deep_dup

    assert_no_difference ["Package.count", "PackageVersion.count", "PackagePaper.count", "PackageProject.count", "ProjectDependency.count", "Paper.count"] do
      report = collect([@version.purl, @version.purl])
      assert_equal({ "complete" => 1 }, report["counts"])
      result = report["versions"].sole
      assert_equal @package.id, result["package_id"]
      assert_equal @version.id, result["package_version_id"]
      assert_equal @version.purl, result["purl"]
      assert_equal @revision, result["revision"]
      assert_equal "huggingface", result.dig("file_list_source", "source")
      assert_equal %w[CITATION.bib README.md], result["files"].map { |row| row["path"] }
      row = result["files"].last
      assert_equal readme, row["content"]
      assert_equal readme.bytesize, row["bytes"]
      assert_equal Digest::SHA256.hexdigest(readme), row["sha256"]
      assert_equal "#{@base_url}/README.md", row["url"]
      assert_equal row["url"], row["resolved_url"]
      assert row["retrieved_at"]
    end
    assert_equal original_package, @package.reload.attributes
    assert_equal original_version, @version.reload.attributes
    assert_equal jobs, Sidekiq::Worker.jobs
    [metadata_request, readme_request, citation_request].each { |request| assert_requested request, times: 1 }
  end

  test "uses the Packages file list only for its matching revision" do
    @package.update!(metadata: { "latest_release_number" => @revision,
      "metadata" => { "files" => ["README.md", "model.safetensors"] } }, ecosystems_checked_at: Time.current)
    file("README.md")
    result = collect["versions"].sole
    assert_equal "packages", result.dig("file_list_source", "source")
    assert_equal @package.ecosystems_id, result.dig("file_list_source", "ecosystems_id")
    assert_equal @package.ecosystems_checked_at.iso8601, result.dig("file_list_source", "retrieved_at")
    assert_not_requested :get, @metadata_url

    @package.update!(metadata: @package.metadata.merge("latest_release_number" => "a" * 40))
    request = metadata(["config.json"])
    file("config.json", body: "{}")
    result = collect["versions"].sole
    assert_equal "huggingface", result.dig("file_list_source", "source")
    assert_equal ["config.json"], result["files"].map { |row| row["path"] }
    assert_requested request, times: 1
  end

  test "keeps a public README when other files are gated missing or throttled" do
    metadata(%w[README.md config.json CITATION.cff codemeta.json CITATION.bib])
    file("README.md", body: "# Public model card")
    file("config.json", status: 401)
    file("CITATION.cff", status: 404)
    file("codemeta.json", status: 429, headers: { "Retry-After" => "60" })
    file("CITATION.bib", status: 503)

    result = collect["versions"].sole

    assert_equal "partial", result["status"]
    files = result["files"].index_by { |row| row["path"] }
    assert_equal "# Public model card", files["README.md"]["content"]
    assert_equal "gated", files["config.json"]["status"]
    assert_equal "missing", files["CITATION.cff"]["status"]
    assert_equal "rate_limited", files["codemeta.json"]["status"]
    assert_equal "60", files["codemeta.json"]["retry_after"]
    assert_equal "error", files["CITATION.bib"]["status"]
    assert_nil files["config.json"]["content"]
  end

  test "follows bounded relative Hub redirects and records the resolved source" do
    metadata(["README.md"])
    target = "/api/resolve-cache/models/google-bert/bert-base-uncased/#{@revision}/README.md"
    file("README.md", status: 307, headers: { "Location" => target })
    stub_request(:get, "https://huggingface.co#{target}").to_return(body: "# BERT")

    row = collect["versions"].sole["files"].sole

    assert_equal "ok", row["status"]
    assert_equal "https://huggingface.co#{target}", row["resolved_url"]
    assert_equal "# BERT", row["content"]
  end

  test "rejects redirects outside HTTPS Hub requests" do
    metadata(["README.md"])
    ["https://example.org/weights", "http://huggingface.co/README.md", "https://user:secret@huggingface.co/README.md"].each do |url|
      file("README.md", status: 302, headers: { "Location" => url })
      row = collect["versions"].sole["files"].sole
      assert_equal "error", row["status"]
      assert_includes row["error"], "HTTPS huggingface.co"
      assert_not_requested :get, url
    end
  end

  test "stops redirect loops" do
    metadata(["README.md"])
    request = file("README.md", status: 302, headers: { "Location" => "#{@base_url}/README.md" })

    row = collect["versions"].sole["files"].sole

    assert_equal "error", row["status"]
    assert_includes row["error"], "Too many"
    assert_requested request, times: 5
  end

  test "bounds both declared and streamed file sizes including error bodies" do
    metadata(["README.md"])
    [
      { body: "small", headers: { "Content-Length" => (1.megabyte + 1).to_s } },
      { body: "x" * (1.megabyte + 1) },
      { body: "x" * (1.megabyte + 1), status: 500 }
    ].each do |options|
      file("README.md", **options)
      row = collect["versions"].sole["files"].sole
      assert_equal "error", row["status"]
      assert_includes row["error"], "exceeds 1 MB"
      assert_nil row["content"]
    end
  end

  test "reports binary or invalid UTF-8 instead of corrupting content" do
    metadata(["README.md"])
    ["a\0b", "\xFF".b].each do |body|
      file("README.md", body: body)
      row = collect["versions"].sole["files"].sole
      assert_equal "error", row["status"]
      assert_includes row["error"], "UTF-8"
      assert_nil row["content"]
    end
  end

  test "a failed or mismatched pinned revision never falls back to latest" do
    responses = [
      { status: 404, body: "missing" },
      { status: 401, body: "gated" },
      { status: 429, body: "throttled" },
      { body: "invalid json" },
      { body: { sha: "a" * 40, siblings: [{ rfilename: "README.md" }] }.to_json },
      { body: { sha: @revision, siblings: [nil] }.to_json },
      { body: "x" * (2.megabytes + 1) }
    ]
    responses.each do |response|
      stub_request(:get, @metadata_url).to_return(response)
      row = collect["versions"].sole
      assert_equal "error", row["status"]
      assert_empty row["files"]
    end
    assert_not_requested :get, %r{/resolve/}
    assert_not_requested :get, "https://huggingface.co/api/models/#{@package.name}"
  end

  test "timeouts are reported without writes or automatic retries" do
    request = stub_request(:get, @metadata_url).to_timeout
    assert_equal "error", collect["versions"].sole["status"]
    assert_requested request, times: 1
  end

  test "a broken HTTP response is reported without losing other files" do
    metadata(%w[README.md config.json])
    file("README.md", body: "# Model")
    stub_request(:get, "#{@base_url}/config.json").to_raise(Net::HTTPBadResponse)

    result = collect["versions"].sole

    assert_equal "partial", result["status"]
    assert_equal "# Model", result["files"].first["content"]
    assert_equal "error", result["files"].last["status"]
    assert_includes result["files"].last["error"], "Net::HTTPBadResponse"
  end

  test "a file list containing only weights collects no files" do
    metadata(%w[model.safetensors config.json/weights README.md/../weights])

    row = collect["versions"].sole

    assert_equal "no_files", row["status"]
    assert_empty row["files"]
    assert_not_requested :get, %r{/resolve/}
  end

  test "validates all selected identities before the first request" do
    [[], {}, nil, [nil], Array.new(26, @version.purl), [@version.purl, @package.purl],
      [@version.purl, "pkg:huggingface/unknown/model@#{@revision}"]].each do |input|
      assert_raises(ArgumentError) { collect(input) }
    end
    ["main", "abc123"].each do |number|
      @version.update!(number: number, purl: "#{@package.purl}@#{number}")
      assert_raises(ArgumentError) { collect }
    end
    @version.update!(number: @revision, purl: "pkg:huggingface/other/model@#{@revision}")
    assert_raises(ArgumentError) { collect }
    assert_not_requested :any, /.*/
  end

  test "rejects malformed and oversized input files before requests" do
    File.write(@file.path, "invalid JSON")
    assert_raises(JSON::ParserError) { invoke }
    File.write(@file.path, " " * (1.megabyte + 1))
    assert_raises(ArgumentError) { invoke }
    assert_not_requested :any, /.*/
  end
end
