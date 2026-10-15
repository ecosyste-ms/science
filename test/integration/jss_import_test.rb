require "test_helper"
require "rake"
require "rubygems/package"
require "zlib"

class JssImportTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("jss:sweep")
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    [ImportJournalWorker, SyncJournalWorker, SyncExternalProjectWorker].each(&:clear)
    @feed = Nokogiri::XML(Rails.root.join("test/fixtures/files/jss/oai.xml").read)
    @feed.remove_namespaces!
    @from = "2026-09-01T00:00:00Z"
    @until = "2026-10-15T00:00:00Z"
  end

  teardown { [ImportJournalWorker, SyncJournalWorker, SyncExternalProjectWorker].each(&:clear) }

  def row(key)
    @feed.xpath("//record").find { |node| node.xpath(".//dc/identifier").any? { |value| value.text.end_with?("/#{key}") } }.dup
  end

  def id(key)
    row(key).at_xpath("./header/identifier").text
  end

  def feed(rows, token: nil)
    "<OAI-PMH><ListRecords>#{rows.map(&:to_xml).join}#{token && "<resumptionToken>#{token}</resumptionToken>"}</ListRecords></OAI-PMH>"
  end

  def no_records
    '<OAI-PMH><error code="noRecordsMatch">No records</error></OAI-PMH>'
  end

  def task(name, **env)
    previous = env.to_h { |key, _| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    JSON.parse(capture_io { Rake::Task[name].invoke }.first)
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def article(key)
    body = Rails.root.join("test/fixtures/files/jss/#{key}.html").read
    body += "<a href='  https://www.jstatsoft.org/index.php/jss/index\n '>Home</a><a href='https://example.org/a b'>Other</a>"
    stub_request(:get, JssClient.article_url(key)).to_return(body: body)
  end

  def archive(entries)
    tar = StringIO.new("".b)
    Gem::Package::TarWriter.new(tar) do |writer|
      entries.each { |name, text| writer.add_file_simple(name, 0o644, text.bytesize) { |file| file.write(text) } }
    end
    output = StringIO.new("".b)
    gzip = Zlib::GzipWriter.new(output)
    gzip.write(tar.string)
    gzip.finish
    output.string
  end

  def package_attachment(key, attachment_id, entries)
    view = "https://www.jstatsoft.org/article/view/#{key}/#{attachment_id}"
    legacy = "https://www.jstatsoft.org/index.php/jss/article/download/#{key}/#{attachment_id}"
    download = "https://www.jstatsoft.org/article/download/#{key}/#{attachment_id}"
    stub_request(:get, view).to_return(status: 302, headers: { "Location" => legacy })
    stub_request(:get, legacy).to_return(status: 303, headers: { "Location" => download })
    stub_request(:get, download).to_return(body: archive(entries))
  end

  def causal_queries(name: "CausalQueries")
    article("v117i01")
    package_attachment("v117i01", 4829, "CausalQueries/DESCRIPTION" => "Package: #{name}\nURL: https://integrated-inferences.github.io/CausalQueries/\nBugReports: https://github.com/integrated-inferences/CausalQueries/issues\nImports: ggplot2, dplyr\n",
      "CausalQueries/README.md" => "https://github.com/tidyverse/ggplot2")
  end

  def manual(key, node: row(key))
    stub_request(:get, JssClient::CATALOGUE_URL).with(query: { verb: "GetRecord", metadataPrefix: "oai_dc", identifier: id(key) })
      .to_return(body: feed([node]))
    task("jss:import", IDS: id(key))
    SyncJournalWorker.perform_one
  end

  def list(rows, set: "jss:ART", token: nil, request_token: nil)
    query = request_token ? { verb: "ListRecords", resumptionToken: request_token } :
      { verb: "ListRecords", metadataPrefix: "oai_dc", set: set, from: @from, until: @until }
    stub_request(:get, JssClient::CATALOGUE_URL).with(query: query).to_return(body: rows.empty? ? no_records : feed(rows, token: token))
  end

  def expire
    ExternalSoftwareRecord.where(source: "jss").update_all(next_refresh_at: 1.minute.ago)
  end

  test "publisher package labels and archive metadata identify subject repositories without dependencies or replication files" do
    project = Project.create!(url: "https://github.com/integrated-inferences/causalqueries", science_score: 42)
    Project.create!(url: "https://github.com/tidyverse/ggplot2")
    score = ScienceScoreCalculator.new(project).calculate
    causal_queries
    manual("v117i01")
    record = ExternalSoftwareRecord.sole
    assert_equal ["https://github.com/integrated-inferences/CausalQueries/issues"], record.metadata["code_urls"]
    package = record.metadata["subject_packages"].sole
    assert_equal "CausalQueries", package["name"]
    assert_equal "cran", package["ecosystem"]
    assert_equal "matched", package["status"]
    assert_equal "10.18637/jss.v117.i01", Paper.sole.doi
    assert_equal [project.id], Paper.sole.linked_projects.pluck(:id)
    assert_equal "package_metadata", project.project_papers.sole.evidence.sole["source_field"]
    assert_equal score, ScienceScoreCalculator.new(project.reload).calculate
    assert_equal 42, project.science_score
    assert_not_requested :get, %r{/4830}
    get project_url(project)
    assert_response :success
    assert_select "[data-role='registry-references'] a[href='https://www.jstatsoft.org/article/view/v117i01']"
    get "/api/v1/projects/#{project.id}/external_identifiers"
    assert_equal "jss", response.parsed_body.sole["scheme"]
    assert_equal JssClient.article_url("v117i01"), response.parsed_body.sole["record_url"]
  end

  test "Python package metadata supplies the repository and discovery creates its project" do
    article("v117i03")
    package_attachment("v117i03", 4835, "asgl-2.2.0/PKG-INFO" => "Name: asgl\nHome-page: https://github.com/alvaromc317/asgl\nRequires-Dist: scipy\n\nhttps://github.com/scipy/scipy\n",
      "asgl-2.2.0/setup.py" => "raise RuntimeError('must not execute')")
    manual("v117i03")
    result = DiscoverExternalRepositoriesWorker.new.perform(10)
    assert_equal 1, result[:sources]["jss"]["created"]
    assert_equal "https://github.com/alvaromc317/asgl", Project.sole.url
    assert_equal "software_description", ProjectPaper.sole.role
    assert_not_requested :get, %r{/4836}
  end

  test "bounded sweeps follow OAI tokens and both eligible sets and retain date checkpoints" do
    causal_queries
    article("v117i04")
    list([row("v117i01"), row("v117i04")], token: "next&amp;page")
    list([row("v117i04")], request_token: "next&page")
    list([], set: "jss:CS")
    task("jss:sweep", FROM: @from, UNTIL: @until, LIMIT: 1)
    ImportJournalWorker.perform_one
    import = ExternalSoftwareImport.find_by!(source: "jss")
    assert_equal 1, JSON.parse(import.cursor)["offset"]
    3.times do
      travel_to import.reload.next_run_at + 1.second do
        ImportJournalWorker.perform_one
      end
    end
    assert import.reload.completed_at
    assert_equal 2, Paper.count
    assert_equal 3, import.items_processed
    assert_equal @until, JSON.parse(import.cursor)["until"]
    task("jss:sweep", RESTART: true)
    assert_equal @until, JSON.parse(import.reload.cursor)["from"]
    assert_raises(ArgumentError) { task("jss:sweep", FROM: "2020-01-01") }
  end

  test "persistent deletion removes journal associations and preserves independent citations" do
    project = Project.create!(url: "https://github.com/integrated-inferences/causalqueries")
    causal_queries
    manual("v117i01")
    link = project.project_papers.sole
    link.update!(role: "reference", evidence: link.evidence + [{ "source" => "citation", "url" => project.url }])
    deleted = row("v117i01")
    deleted.at_xpath("./metadata").remove
    deleted.at_xpath("./header")["status"] = "deleted"
    expire
    manual("v117i01", node: deleted)
    assert_equal "missing", ExternalSoftwareRecord.sole.status
    assert_empty project.project_external_software_records
    assert_equal ["citation"], link.reload.evidence.pluck("source")
    assert_equal 1, Paper.count
    assert_nil ExternalSoftwareRecord.sole.next_discovery_at
  end

  test "unknown deletions and review records do not create publications or projects" do
    deleted = row("v117i01")
    deleted.at_xpath("./metadata").remove
    deleted.at_xpath("./header")["status"] = "deleted"
    manual("v117i01", node: deleted)
    review = row("v117i03")
    review.at_xpath("./header/setSpec").content = "jss:BR"
    manual("v117i03", node: review)
    assert_equal false, ExternalSoftwareRecord.find_by!(identifier: id("v117i03")).metadata["eligible"]
    assert_empty Paper.all
    assert_empty Project.all
    assert_not_requested :get, JssClient.article_url("v117i03")
  end

  test "combined source and replication files remain unresolved without downloading them" do
    article("v117i04")
    manual("v117i04")
    record = ExternalSoftwareRecord.sole
    assert_empty record.metadata["subject_packages"]
    assert_empty record.metadata["code_urls"]
    assert_includes record.metadata["attachments"].pluck("label"), "Source code and replication files"
    assert_equal 1, Paper.count
    assert_not_requested :get, %r{/4838}
  end

  test "package names that disagree with publisher labels cannot establish a repository" do
    causal_queries(name: "ggplot2")
    manual("v117i01")
    package = ExternalSoftwareRecord.sole.metadata["subject_packages"].sole
    assert_equal "unresolved", package["status"]
    assert_match "disagrees", package["reason"]
    assert_empty ExternalSoftwareRecord.sole.metadata["code_urls"]
  end

  test "expired tokens restart the saved set and date window without duplicating papers" do
    article("v117i04")
    list([row("v117i04")], token: "expired")
    task("jss:sweep", FROM: @from, UNTIL: @until)
    ImportJournalWorker.perform_one
    import = ExternalSoftwareImport.find_by!(source: "jss")
    assert_equal "expired", JSON.parse(import.cursor)["token"]
    stub_request(:get, JssClient::CATALOGUE_URL).with(query: { verb: "ListRecords", resumptionToken: "expired" })
      .to_return(body: '<OAI-PMH><error code="badResumptionToken">Expired</error></OAI-PMH>')
    Rails.cache.clear
    list([row("v117i04")])
    travel_to import.next_run_at + 1.second do
      ImportJournalWorker.perform_one
    end
    assert_equal 1, Paper.count
    assert_equal "jss:CS", JSON.parse(import.reload.cursor)["set"]
  end

  test "DOI mismatches leave the previously imported evidence intact" do
    causal_queries
    manual("v117i01")
    before = ExternalSoftwareRecord.sole.metadata
    expire
    body = Rails.root.join("test/fixtures/files/jss/v117i01.html").read.gsub("10.18637/jss.v117.i01", "10.18637/jss.v117.i02")
    stub_request(:get, JssClient.article_url("v117i01")).to_return(body: body)
    assert_raises(JournalHttpClient::Error) { manual("v117i01") }
    assert_equal before, ExternalSoftwareRecord.sole.metadata
    assert_equal "error", ExternalSoftwareRecord.sole.status
  end

  test "oversized archive metadata cannot produce project associations" do
    article("v117i01")
    package_attachment("v117i01", 4829, "CausalQueries/DESCRIPTION" => "Package: CausalQueries\nURL: #{'x' * 270_000}")
    manual("v117i01")
    package = ExternalSoftwareRecord.sole.metadata["subject_packages"].sole
    assert_equal "unresolved", package["status"]
    assert_match "256 KB", package["reason"]
    assert_empty ProjectPaper.all
  end
end
