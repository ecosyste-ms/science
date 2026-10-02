module BiotoolsPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_biotools_jobs
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @biotools = JSON.parse(Rails.root.join("test/fixtures/files/biotools.json").read)
        .index_by { |record| record.fetch("biotoolsID") }
    end
    teardown { clear_biotools_jobs }
  end

  def clear_biotools_jobs
    ImportBiotoolsWorker.clear
    SyncBiotoolsWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncBiotoolsWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def biotools_record(id, payload: @biotools[id], status: 200, headers: {})
    stub_request(:get, "#{BiotoolsClient::API_URL}#{id}/").with(query: { format: "json" })
      .to_return(status: status, headers: headers, body: payload.to_json)
  end

  def biotools_page(number, ids, next_page: nil, limit: 2, status: 200, headers: {})
    stub_request(:get, BiotoolsClient::API_URL)
      .with(query: { format: "json", page: number, per_page: limit, sort: "additionDate", ord: "asc" })
      .to_return(status: status, headers: headers,
        body: { count: 4, list: ids.map { |id| @biotools.fetch(id) }, next: next_page && "?page=#{next_page}" }.to_json)
  end
end
