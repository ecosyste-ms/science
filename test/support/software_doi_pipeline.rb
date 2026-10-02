module SoftwareDoiPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_doi_jobs
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @datacite = JSON.parse(Rails.root.join("test/fixtures/files/software_doi_datacite.json").read).index_by { |record| record["id"] }
      @zenodo = JSON.parse(Rails.root.join("test/fixtures/files/software_doi_zenodo.json").read).index_by { |record| record["doi"] }
    end
    teardown { clear_doi_jobs }
  end

  def clear_doi_jobs
    ImportSoftwareDoiSeedsWorker.clear
    SyncSoftwareDoiWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncSoftwareDoiWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def doi_project(url: "https://github.com/example/tool", doi: nil, hidden: false, **attributes)
    project = Project.create!({ url: url, science_score: 42, citation_file: doi && "cff-version: 1.2.0\nmessage: Cite this software\ntitle: Software\nauthors:\n  - name: Research team\ndoi: #{doi}\n" }.merge(attributes))
    IndexSoftwareSearchWorker.new.perform(project.id)
    if hidden
      owner = Owner.create!(host: Host.find_or_create_by!(name: "GitHub"), login: "hidden", hidden: true)
      project.update_columns(owner_id: owner.id)
    end
    project.reload
  end

  def datacite_record(id, body: nil, status: 200, headers: {})
    stub_request(:get, SoftwareDoiClient.collection_url(id))
      .to_return(status: status, headers: headers, body: (body || { data: @datacite.fetch(id) }).to_json)
  end

  def zenodo_record(id)
    record = @zenodo[id] || @zenodo.values.find { |item| item["conceptdoi"] == id }
    url = "#{SoftwareDoiClient::ZENODO_URL}/#{id.split('.').last}"
    if record["doi"] != id
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "#{SoftwareDoiClient::ZENODO_URL}/#{record['id']}" })
      url = "#{SoftwareDoiClient::ZENODO_URL}/#{record['id']}"
    end
    stub_request(:get, url).to_return(body: record.to_json)
  end

  def doi_record(id)
    datacite_record(id)
    zenodo_record(id) if id.start_with?("10.5281/") && @datacite[id].dig("attributes", "types", "resourceTypeGeneral") == "Software"
  end

  def sync_dois(ids)
    SyncSoftwareDoiWorker.perform_async(ids)
    SyncSoftwareDoiWorker.perform_one
  end

  def expire_dois
    clear_doi_jobs
    ExternalSoftwareRecord.where(source: "doi").update_all(next_refresh_at: 1.minute.ago)
  end
end
