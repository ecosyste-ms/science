require "test_helper"
require_relative "../support/ascl_pipeline"

class AsclCacheTest < ActiveSupport::TestCase
  include AsclPipeline

  class BoundedCache < ActiveSupport::Cache::MemoryStore
    def write(key, value, **options)
      raise "Cache item exceeds 1 MB" if Marshal.dump(value).bytesize > 1.megabyte
      super
    end
  end

  test "worker caches a large catalogue in bounded entries and preserves Unicode across chunk boundaries" do
    Rails.stubs(:cache).returns(BoundedCache.new(compress: false))
    @ascl["1609.011"]["abstract"] = "Astronomie αβ星 " * 100_000
    request = ascl_catalogue
    SyncAsclWorker.new.perform(["1010.083"])
    manifest = Rails.cache.read(AsclClient::CACHE_KEY)
    assert manifest.fetch("keys").size > 4
    manifest.fetch("keys").each do |key|
      assert Rails.cache.read(key).bytesize <= AsclClient::CACHE_CHUNK_BYTES
    end
    SyncAsclWorker.new.perform(["1609.011"])
    record = ExternalSoftwareRecord.find_by!(source: "ascl", identifier: "1609.011")
    assert_equal @ascl["1609.011"], record.metadata
    assert_requested request, times: 1
  end

  test "an evicted cache chunk triggers validated retrieval instead of a partial catalogue" do
    request = ascl_catalogue
    SyncAsclWorker.new.perform(["1010.083"])
    first_keys = Rails.cache.read(AsclClient::CACHE_KEY).fetch("keys")
    Rails.cache.delete(first_keys.first)
    SyncAsclWorker.new.perform(["1609.011"])
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: "1609.011").status
    assert_empty first_keys & Rails.cache.read(AsclClient::CACHE_KEY).fetch("keys")
    assert_requested request, times: 2
  end

  test "cache write failures do not publish an incomplete snapshot or prevent imports" do
    request = ascl_catalogue
    Rails.cache.stubs(:write).returns(false)
    SyncAsclWorker.new.perform(["1010.083"])
    assert_nil Rails.cache.read(AsclClient::CACHE_KEY)
    SyncAsclWorker.new.perform(["1609.011"])
    assert_equal %w[ok ok], ExternalSoftwareRecord.order(:identifier).pluck(:status)
    assert_requested request, times: 2
  end

  test "an incomplete cache cannot hide an upstream validation failure" do
    ascl_catalogue
    SyncAsclWorker.new.perform(["1609.011"])
    record = ExternalSoftwareRecord.sole
    metadata = record.metadata
    Rails.cache.delete(Rails.cache.read(AsclClient::CACHE_KEY).fetch("keys").first)
    record.update!(next_refresh_at: 1.minute.ago)
    ascl_catalogue(@ascl.values.reject { |entry| entry["ascl_id"] == "1609.011" },
      index: @ascl.keys.map { |id| { "ascl_id" => id } })
    assert_raises(AsclClient::Error) { SyncAsclWorker.new.perform(["1609.011"]) }
    assert_equal "error", record.reload.status
    assert_equal metadata, record.metadata
  end
end
