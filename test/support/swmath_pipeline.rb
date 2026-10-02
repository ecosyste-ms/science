module SwmathPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_swmath_jobs
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @swmath = JSON.parse(Rails.root.join("test/fixtures/files/swmath.json").read).index_by { |record| record.fetch("id").to_s }
    end
    teardown { clear_swmath_jobs }
  end

  def clear_swmath_jobs
    ImportSwmathWorker.clear
    SyncSwmathWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncSwmathWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def swmath_response(result, total: nil, last_id: nil)
    count = result.is_a?(Array) ? result.size : 1
    { "result" => result, "status" => { "execution_bool" => true, "internal_code" => "ok", "status_code" => 200,
      "nr_request_results" => count, "nr_total_results" => total || count, "last_id" => last_id } }
  end

  def swmath_record(id, body: nil, status: 200, headers: {})
    stub_request(:get, "#{SwmathClient::API_URL}/#{id}")
      .to_return(status: status, headers: headers, body: (body || swmath_response(@swmath.fetch(id))).to_json)
  end

  def swmath_page(after:, ids:, limit: 2, total: nil, body: nil, status: 200)
    records = ids.map { |id| @swmath.fetch(id) }
    stub_request(:get, "#{SwmathClient::API_URL}/_all")
      .with(query: { start_after: after, results_per_request: limit })
      .to_return(status: status, body: (body || swmath_response(records, total: total, last_id: records.last&.fetch("id"))).to_json)
  end

  def swmath_missing(code: 200)
    { "result" => nil, "status" => { "execution_bool" => false, "status_code" => code,
      "internal_code" => code == 200 ? "Entry not found! internal code: id does not exist!" : "successful access, but no result" } }
  end

  def expire_swmath
    clear_swmath_jobs
    ExternalSoftwareRecord.where(source: "swmath").update_all(next_refresh_at: 1.minute.ago)
  end

  def sync_swmath(ids)
    SyncSwmathWorker.perform_async(ids)
    SyncSwmathWorker.perform_one
  end
end
