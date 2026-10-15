require "test_helper"
require "rake"

class JorsImportTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("jors:sweep")
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    [ImportJournalWorker, SyncJournalWorker, SyncExternalProjectWorker].each(&:clear)
  end

  teardown { [ImportJournalWorker, SyncJournalWorker, SyncExternalProjectWorker].each(&:clear) }

  def article(number, body: nil)
    id = "10.5334/jors.#{number}"
    xml_url = "https://#{JorsClient::HOST}/articles/#{number}/files/article.xml"
    stub_request(:get, JorsClient.article_url(id)).to_return(body: "<a href='#{xml_url}'>XML (English)</a>")
    stub_request(:get, xml_url).to_return(body: body || Rails.root.join("test/fixtures/files/jors/#{number}.xml").read)
  end

  def task(name, **env)
    previous = env.to_h { |key, _| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    JSON.parse(capture_io { Rake::Task[name].invoke }.first)
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def sync(*numbers)
    task("jors:import", IDS: numbers.map { |number| "10.5334/jors.#{number}" }.join(","))
    SyncJournalWorker.perform_one
  end

  def expire
    ExternalSoftwareRecord.where(source: "jors").update_all(next_refresh_at: 1.minute.ago)
  end

  def listing(page, numbers, more: false)
    body = "<title>Articles | Journal of Open Research Software</title>"
    body += numbers.map { |number| "<a href='/en/articles/10.5334/jors.#{number}'>Article</a>" }.join
    body += "<a href='/en/articles?page=#{page + 1}'>Next page</a>" if more
    stub_request(:get, "#{JorsClient::CATALOGUE_URL}?page=#{page}").to_return(body: body)
  end

  test "RSE links both subject repositories and retains separate archive and package URLs" do
    first = Project.create!(url: "https://github.com/rseng/rse", science_score: 42)
    second = Project.create!(url: "https://github.com/rseng/rseng")
    unrelated = Project.create!(url: "https://github.com/dask/dask")
    score = ScienceScoreCalculator.new(first).calculate
    article(359)
    sync(359)
    paper = Paper.sole
    assert_equal "10.5334/jors.359", paper.doi
    assert_equal [first.id, second.id].sort, paper.linked_projects.pluck(:id).sort
    assert_equal "software_description", first.project_papers.sole.role
    assert_empty unrelated.project_papers
    record = ExternalSoftwareRecord.sole
    assert_equal [first.url, second.url], record.metadata["code_urls"]
    assert_includes record.metadata["software_links"], "https://pypi.org/project/rse/0.0.34/"
    assert record.metadata["software_links"].any? { |url| url.include?("zenodo.org/record/") }
    assert_equal "software_location", first.project_papers.sole.evidence.sole["source_field"]
    assert_equal score, ScienceScoreCalculator.new(first.reload).calculate
    assert_equal 42, first.science_score
    assert_empty Mention.all
    get project_url(first)
    assert_response :success
    assert_select "[data-related-paper-id='#{paper.id}']", text: /Software description/
    get "/api/v1/projects/#{first.id}/external_identifiers"
    assert_response :success
    assert_equal "jors", response.parsed_body.sole["scheme"]
  end

  test "workshop reports remain excluded even when their body contains repository links" do
    article(85)
    sync(85)
    record = ExternalSoftwareRecord.sole
    assert_equal false, record.metadata["eligible"]
    assert_empty record.metadata["code_urls"]
    assert_empty Paper.all
    result = DiscoverExternalRepositoriesWorker.new.perform(10)
    assert_equal 1, result[:processed]
    assert_empty Project.all
  end

  test "numbered sections dot git URLs and corroborated plain-text identifiers support discovery" do
    [771, 694, 585, 743, 736].each { |number| article(number) }
    sync(771, 694, 585, 743, 736)
    result = DiscoverExternalRepositoriesWorker.new.perform(10)
    assert_equal 5, result[:sources]["jors"]["created"]
    assert_equal 5, Paper.count
    assert_equal 5, ProjectPaper.count
    assert Project.exists?(url: "https://github.com/snigdha-sen/microtorch")
    assert Project.exists?(url: "https://github.com/safwanaljbaae/gravdyn")
    assert Project.exists?(url: "https://gitlab.com/dma-uem/bigvrsp")
    assert_not Project.exists?(url: "https://github.com/non-gon/testing-dataset")
    assert_not Project.exists?(url: "https://github.com/liabru/matter-js")
    assert_equal "10.5334/jors.771", Paper.find_by!(title: "Making Soundscape Assessment Accessible: The SoundGraphy Tool").doi
  end

  test "plain-text GitHub identifiers need a corroborating URL" do
    body = Rails.root.join("test/fixtures/files/jors/736.xml").read.gsub("https://github.com/snigdha-sen/microtorch", "https://example.org/software")
    article(736, body: body)
    sync(736)
    assert_empty ExternalSoftwareRecord.sole.metadata["code_urls"]
    assert_match "snigdha-sen/microtorch", ExternalSoftwareRecord.sole.metadata["software_sections"].sole["text"]
  end

  test "publisher DOI reuses an existing OpenAlex paper and preserves its metadata" do
    paper = Paper.create!(doi: "https://doi.org/10.5334/JORS.359", openalex_id: "W123", title: "Enriched title", openalex_data: { "id" => "W123" })
    article(359)
    assert_no_difference "Paper.count" do
      sync(359)
    end
    assert_equal "Enriched title", paper.reload.title
    assert_equal({ "id" => "W123" }, paper.openalex_data)
    assert_equal "10.5334/jors.359", paper.paper_identifiers.sole.identifier
    assert_equal "10.5334/jors.359", paper.doi
  end

  test "sweeps persist bounded pages and resume through publisher pagination" do
    listing(1, [359, 85, 736], more: true)
    listing(2, [743])
    [359, 85, 736, 743].each { |number| article(number) }
    assert_equal 2, task("jors:sweep", LIMIT: 2)["page_size"]
    ImportJournalWorker.perform_one
    import = ExternalSoftwareImport.find_by!(source: "jors")
    assert_equal "1:2", import.cursor
    assert_equal 2, import.items_processed
    travel_to import.next_run_at + 1.second do
      ImportJournalWorker.perform_one
    end
    assert_equal "2:0", import.reload.cursor
    travel_to import.next_run_at + 1.second do
      ImportJournalWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 4, import.items_processed
    assert_equal 3, Paper.count
    assert_equal true, task("jors:status")["complete"]
    assert_equal false, task("jors:resume")["queued"]
  end

  test "saved XML records survive a matching failure without refetching the page" do
    listing(1, [359])
    article(359)
    task("jors:sweep")
    JorsImporter.any_instance.stubs(:sync_page).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportJournalWorker.perform_one }
    import = ExternalSoftwareImport.find_by!(source: "jors")
    assert_equal 1, import.pending_records.size
    JorsImporter.any_instance.unstub(:sync_page)
    WebMock.reset!
    travel_to import.next_run_at + 1.second do
      task("jors:resume")
      ImportJournalWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 1, Paper.count
  end

  test "reclassification removes only journal evidence while retaining the publication" do
    project = Project.create!(url: "https://github.com/rseng/rse")
    article(359)
    sync(359)
    paper = Paper.sole
    pair = project.project_papers.sole
    pair.update!(role: "reference", evidence: pair.evidence + [{ "source" => "citation", "url" => project.url }])
    expire
    body = Rails.root.join("test/fixtures/files/jors/359.xml").read.sub("Software metapaper", "Issues in research software")
    article(359, body: body)
    sync(359)
    assert_empty project.project_external_software_records
    assert_equal ["citation"], pair.reload.evidence.pluck("source")
    assert_equal paper.id, pair.paper_id
  end

  test "invalid XML and DOI conflicts preserve the previous source snapshot" do
    article(359)
    sync(359)
    before = ExternalSoftwareRecord.sole.metadata
    ["<article>", Rails.root.join("test/fixtures/files/jors/359.xml").read.sub("10.5334/jors.359", "10.5334/jors.85")].each do |body|
      expire
      article(359, body: body)
      task("jors:import", IDS: "10.5334/jors.359")
      assert_raises(JournalHttpClient::Error) { SyncJournalWorker.perform_one }
      assert_equal before, ExternalSoftwareRecord.sole.metadata
      assert_equal "error", ExternalSoftwareRecord.sole.status
    end
  end

  test "rate limits defer a sweep and share cooldown across article requests" do
    stub_request(:get, "#{JorsClient::CATALOGUE_URL}?page=1").to_return(status: 429, headers: { "Retry-After" => "600" })
    task("jors:sweep")
    ImportJournalWorker.perform_one
    import = ExternalSoftwareImport.find_by!(source: "jors")
    assert import.next_run_at >= 9.minutes.from_now
    assert_equal 0, import.items_processed
    assert_raises(JournalHttpClient::RateLimited) { JorsClient.new.article("10.5334/jors.359") }
  end

  test "off-host XML downloads and invalid task arguments are rejected" do
    stub_request(:get, JorsClient.article_url("10.5334/jors.359")).to_return(body: '<a href="https://example.org/articles/359/files/article.xml">XML (English)</a>')
    task("jors:import", IDS: "10.5334/jors.359")
    assert_raises(JournalHttpClient::Error) { SyncJournalWorker.perform_one }
    assert_not_requested :any, /example.org/
    assert_raises(ArgumentError) { task("jors:import", IDS: "10.5281/zenodo.123") }
    assert_raises(ArgumentError) { task("jors:sweep", LIMIT: 6) }
    assert_raises(ArgumentError) { task("jors:refresh", LIMIT: 1001) }
  end

  test "publisher redirects are followed within the host and redirect loops are bounded" do
    listing(1, [359])
    article(359)
    stub_request(:get, "#{JorsClient::CATALOGUE_URL}?page=1").to_return(status: 307,
      headers: { "Location" => "/articles?page=1" })
    stub_request(:get, "https://#{JorsClient::HOST}/articles?page=1").to_return(body:
      '<title>Journal of Open Research Software</title><a href="/articles/10.5334/jors.359">Article</a>')
    task("jors:sweep")
    ImportJournalWorker.perform_one
    assert ExternalSoftwareImport.sole.completed_at
    expire
    stub_request(:get, JorsClient.article_url("10.5334/jors.359")).to_return(status: 302,
      headers: { "Location" => JorsClient.article_url("10.5334/jors.359") })
    task("jors:import", IDS: "10.5334/jors.359")
    error = assert_raises(JournalHttpClient::Error) { SyncJournalWorker.perform_one }
    assert_match "Too many", error.message
    stub_request(:get, JorsClient.article_url("10.5334/jors.359")).to_return(status: 302,
      headers: { "Location" => "https://example.org/article" })
    expire
    task("jors:import", IDS: "10.5334/jors.359")
    assert_raises(JournalHttpClient::Error) { SyncJournalWorker.perform_one }
    assert_not_requested :any, /example.org/
  end
end
