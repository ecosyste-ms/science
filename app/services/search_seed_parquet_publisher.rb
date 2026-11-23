require "aws-sdk-s3"
require "digest"

class SearchSeedParquetPublisher
  LATEST_KEY = "clues/latest.json"
  MAX_POINTER_WRITES = 4
  SNAPSHOT_ID = /\A[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}\z/i

  def initialize(directory:, bucket:, client: Aws::S3::Client.new)
    @directory = directory
    @bucket = bucket
    @client = client
  end

  def publish
    manifest_path = File.join(@directory, "manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    id = manifest.fetch("snapshot_id")
    raise ArgumentError, "invalid snapshot ID" unless id.match?(SNAPSHOT_ID)

    started_at = Time.iso8601(manifest.fetch("started_at"))
    filenames = SearchSeedParquetExport::QUERIES.keys.map { |name| "#{name}.parquet" }
    unless manifest.fetch("files").keys.sort == filenames.sort
      raise ArgumentError, "manifest does not list the expected Parquet files"
    end

    base = "clues/snapshots/#{id}"
    manifest_key = "#{base}/manifest.json"
    filenames.each { |name| upload(File.join(@directory, name), "#{base}/#{name}", "application/octet-stream") }
    upload(manifest_path, manifest_key, "application/json")
    pointer = { snapshot_id: id, started_at: manifest.fetch("started_at"), manifest: manifest_key }
    { bucket: @bucket, manifest: manifest_key, latest: advance_latest(pointer, started_at) }
  end

  def upload(path, key, content_type)
    checksum = Digest::SHA256.file(path).base64digest
    File.open(path, "rb") do |file|
      @client.put_object(bucket: @bucket, key: key, body: file, content_type: content_type,
        checksum_sha256: checksum, if_none_match: "*")
    end
  rescue Aws::S3::Errors::PreconditionFailed
    stored = @client.head_object(bucket: @bucket, key: key, checksum_mode: "ENABLED")
    raise IOError, "different content already exists at #{key}" unless stored.checksum_sha256 == checksum
  end

  def advance_latest(pointer, started_at)
    key = LATEST_KEY
    params = { bucket: @bucket, key: key, body: JSON.generate(pointer),
      content_type: "application/json", cache_control: "no-cache" }
    condition = { if_none_match: "*" }
    MAX_POINTER_WRITES.times do |attempt|
      begin
        @client.put_object(**params, **condition)
        return true
      rescue Aws::S3::Errors::PreconditionFailed, Aws::S3::Errors::ConditionalRequestConflict => conflict
        begin
          current = @client.get_object(bucket: @bucket, key: key)
          published = JSON.parse(current.body.read)
          return true if published.fetch("snapshot_id") == pointer.fetch(:snapshot_id)
          return false if Time.iso8601(published.fetch("started_at")) >= started_at
          condition = { if_match: current.etag }
        rescue Aws::S3::Errors::NoSuchKey
          condition = { if_none_match: "*" }
        end
        raise conflict if attempt + 1 == MAX_POINTER_WRITES
      end
    end
  end
end
