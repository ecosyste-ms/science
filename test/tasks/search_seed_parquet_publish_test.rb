require "test_helper"
require "rake"
require "aws-sdk-s3"

class SearchSeedParquetPublishTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("search_seeds:publish_parquet")
    @task = Rake::Task["search_seeds:publish_parquet"]
    @task.reenable
    @env = ENV.to_h.slice("OUTPUT", "CLUE_EXPORT_BUCKET")
    @directory = Dir.mktmpdir
    ENV["OUTPUT"] = @directory
    ENV["CLUE_EXPORT_BUCKET"] = "test-exports"
    @client = Aws::S3::Client.new(stub_responses: true)
    Aws::S3::Client.stubs(:new).returns(@client)
    @files = %w[clues.parquet candidates.parquet provenance.parquet]
    @files.each { |name| File.binwrite(File.join(@directory, name), "contents of #{name}") }
    @id = SecureRandom.uuid
    @manifest = {snapshot_id: @id, started_at: "2026-01-01T00:00:00Z", files: @files.index_with { 1 }}
    File.write(File.join(@directory, "manifest.json"), JSON.generate(@manifest))
  end

  teardown do
    %w[OUTPUT CLUE_EXPORT_BUCKET].each { |key| ENV[key] = @env[key] }
    FileUtils.remove_entry(@directory)
  end

  test "publishes data, manifest, then a pointer to that snapshot" do
    output, = capture_io { @task.invoke }
    base = "clues/snapshots/#{@id}"
    assert JSON.parse(output).fetch("latest")
    puts_sent = @client.api_requests.map { |request| request.fetch(:params) }
    assert_equal (@files + ["manifest.json"]).map { |name| "#{base}/#{name}" } + ["clues/latest.json"], puts_sent.pluck(:key)
    assert puts_sent.all? { |put| put[:if_none_match] == "*" }
    assert_equal Digest::SHA256.file(File.join(@directory, @files.first)).base64digest, puts_sent.first[:checksum_sha256]
    assert_equal "#{base}/manifest.json", JSON.parse(puts_sent.last[:body]).fetch("manifest")
  end

  test "scheduled task propagates export failures before publishing" do
    SearchSeedParquetExport.any_instance.expects(:export).raises(IOError, "disk full")
    task = Rake::Task["search_seeds:export_and_publish"]
    task.reenable
    assert_raises(IOError) { task.invoke }
    assert_empty @client.api_requests
  end

  test "retry after the first upload verifies it and advances latest only after the manifest" do
    stored_checksum = nil
    @client.stub_responses(:put_object, lambda { |ctx|
      stored_checksum = Digest::SHA256.base64digest(ctx.params.fetch(:body).read)
      {}
    }, "AccessDenied")
    assert_raises(Aws::S3::Errors::AccessDenied) { @task.invoke }
    requests = @client.api_requests.dup
    base = "clues/snapshots/#{@id}"
    assert_equal ["#{base}/clues.parquet", "#{base}/candidates.parquet"], requests.pluck(:params).pluck(:key)
    assert_equal requests.first[:params][:checksum_sha256], stored_checksum

    @client.stub_responses(:put_object, "PreconditionFailed", {}, {}, {}, "PreconditionFailed", {})
    @client.stub_responses(:head_object, checksum_sha256: stored_checksum)
    previous = {snapshot_id: SecureRandom.uuid, started_at: "2025-12-31T00:00:00Z"}
    @client.stub_responses(:get_object, body: JSON.generate(previous), etag: '"previous"')
    @task.reenable
    output, = capture_io { @task.invoke }
    assert JSON.parse(output).fetch("latest")
    retry_requests = @client.api_requests.drop(requests.length)
    assert_equal [
      [:put_object, "#{base}/clues.parquet"],
      [:head_object, "#{base}/clues.parquet"],
      [:put_object, "#{base}/candidates.parquet"],
      [:put_object, "#{base}/provenance.parquet"],
      [:put_object, "#{base}/manifest.json"],
      [:put_object, "clues/latest.json"],
      [:get_object, "clues/latest.json"],
      [:put_object, "clues/latest.json"]
    ], retry_requests.map { |r| [r[:operation_name], r[:params][:key]] }
    assert_equal "*", retry_requests.first[:params][:if_none_match]
    assert_equal "ENABLED", retry_requests[1][:params][:checksum_mode]
    assert_equal "*", retry_requests[-3][:params][:if_none_match]
    latest = retry_requests.last.fetch(:params)
    assert_equal '"previous"', latest.fetch(:if_match)
    assert_equal "#{base}/manifest.json", JSON.parse(latest.fetch(:body)).fetch("manifest")
  end

  test "retry refuses to publish when the stored file has different contents" do
    @client.stub_responses(:put_object, "PreconditionFailed")
    @client.stub_responses(:head_object, checksum_sha256: Digest::SHA256.base64digest("different clues"))
    assert_raises(IOError) { @task.invoke }
    assert_equal [:put_object, :head_object], @client.api_requests.pluck(:operation_name)
    assert_equal ["clues/snapshots/#{@id}/clues.parquet"], @client.api_requests.pluck(:params).pluck(:key).uniq
  end

  test "republishing an older snapshot preserves the newer pointer" do
    @client.stub_responses(:put_object, {}, {}, {}, {}, "PreconditionFailed")
    @client.stub_responses(:get_object, body: JSON.generate(snapshot_id: SecureRandom.uuid, started_at: "2026-01-02T00:00:00Z"))
    output, = capture_io { @task.invoke }
    assert_equal false, JSON.parse(output).fetch("latest")
    assert_equal :get_object, @client.api_requests.last[:operation_name]
  end
end
