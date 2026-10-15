require "test_helper"
require "rake"
require_relative "../support/mloss_pipeline"
require_relative "../support/journal_schedule"

class JournalPaperEnrichmentTest < ActiveSupport::TestCase
  include MlossPipeline
  include JournalSchedule

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("journals:enrich")
    @previous_env = ENV.to_h.slice("OPENALEX_API_KEY", "LIMIT", "IDS")
    ENV["OPENALEX_API_KEY"] = "test-key"
    ENV.delete("LIMIT")
    clear_enrichment_jobs
    @work = { "id" => "https://openalex.org/W12345678", "doi" => "https://doi.org/10.18637/jss.v117.i01",
      "title" => "CausalQueries", "publication_date" => "2025-12-01", "cited_by_count" => 10,
      "primary_location" => { "landing_page_url" => "https://www.jstatsoft.org/article/view/v117i01",
        "source" => { "id" => "https://openalex.org/S1234", "display_name" => "Journal of Statistical Software", "type" => "journal" } } }
  end

  teardown do
    %w[OPENALEX_API_KEY LIMIT IDS].each { |key| ENV[key] = @previous_env[key] }
    clear_enrichment_jobs
  end

  def clear_enrichment_jobs
    EnrichJournalPaperWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{EnrichJournalPaperWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def jss_paper(number = 1)
    Paper.import_publication!(title: "Publisher title #{number}", url: "https://www.jstatsoft.org/article/view/v117i#{number.to_s.rjust(2, '0')}",
      doi: "10.18637/jss.v117.i#{number.to_s.rjust(2, '0')}")
  end

  def lookup(path = "doi:10.18637/jss.v117.i01", work: @work, status: 200, headers: {})
    stub_request(:get, "https://api.openalex.org/works/#{path}").with(query: { api_key: "test-key" })
      .to_return(status: status, body: work.to_json, headers: headers)
  end

  def search(paper, works, count: works.size)
    stub_request(:get, "https://api.openalex.org/works").with(query: {
      api_key: "test-key", "search.title" => paper.title.scan(/[\p{L}\p{N}]+/).join(" "), per_page: "100"
    }).to_return(body: { meta: { count: count }, results: works }.to_json)
  end

  def enrich
    scheduled_journal_tasks("journals", "enrich").sole
  end

  def import_mloss
    mloss_catalogue
    ENV["IDS"] = "v27/26-0434"
    Rake::Task["mloss:import"].reenable
    capture_io { Rake::Task["mloss:import"].invoke }
    SyncMlossWorker.perform_one
    Paper.sole
  end

  test "scheduled enrichment finds a DOI-less publisher paper and preserves software evidence" do
    project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator", science_score: 42)
    paper = import_mloss
    evidence = project.project_papers.sole.evidence
    work = @work.merge("doi" => nil, "title" => paper.title,
      "primary_location" => { "pdf_url" => "http://jmlr.org/papers/volume27/26-0434/26-0434.pdf",
        "source" => { "id" => "https://openalex.org/S5678", "display_name" => "Journal of Machine Learning Research" } })
    request = search(paper, [work, work.merge("id" => "https://openalex.org/W999", "primary_location" => nil)])
    assert_equal({ "queued" => 1, "status" => "ready" }, enrich)
    assert_no_difference ["Paper.count", "ProjectPaper.count", "PaperIdentifier.count"] do
      EnrichJournalPaperWorker.perform_one
    end
    assert_equal work, paper.reload.openalex_data
    assert_equal work["id"], paper.openalex_id
    assert_equal "Journal of Machine Learning Research", paper.openalex_data.dig("primary_location", "source", "display_name")
    assert_equal "software_description", project.project_papers.sole.role
    assert_equal evidence, project.project_papers.sole.evidence
    assert_equal 42, project.reload.science_score
    assert_equal "ok", JournalPaperEnrichment.sole.status
    assert_requested request, times: 1
  end

  test "DOI enrichment updates the existing paper and refreshes by OpenAlex ID after thirty days" do
    paper = jss_paper
    paper.update!(doi: "https://doi.org/10.18637/JSS.V117.I01")
    request = lookup
    enrich
    EnrichJournalPaperWorker.perform_one
    record = JournalPaperEnrichment.sole
    assert_equal "ok", record.status
    assert_equal @work, paper.reload.openalex_data
    assert_equal paper.id, record.paper_id
    assert_in_delta 30.days.from_now.to_f, record.next_attempt_at.to_f, 2
    assert_equal 0, enrich.fetch("queued")
    assert_requested request, times: 1

    refreshed = @work.merge("cited_by_count" => 15)
    request = lookup("W12345678", work: refreshed)
    travel_to record.next_attempt_at + 1.second do
      assert_equal 1, enrich.fetch("queued")
      EnrichJournalPaperWorker.perform_one
      assert_equal refreshed, paper.reload.openalex_data
      assert_in_delta Time.current.to_f, record.reload.checked_at.to_f, 1
    end
    assert_equal 1, Paper.count
    assert_requested request, times: 1
  end

  test "unchanged metadata still records a successful check and delays the next refresh" do
    paper = jss_paper
    lookup
    enrich
    EnrichJournalPaperWorker.perform_one
    synced_at = paper.reload.last_synced_at
    record = JournalPaperEnrichment.sole
    lookup("W12345678")
    travel_to record.next_attempt_at + 1.second do
      enrich
      EnrichJournalPaperWorker.perform_one
      assert_equal synced_at, paper.reload.last_synced_at
      assert_in_delta Time.current.to_f, record.reload.checked_at.to_f, 1
      assert_in_delta 30.days.from_now.to_f, record.next_attempt_at.to_f, 1
    end
  end

  test "a title match without publisher identity is left unresolved and retried later" do
    paper = import_mloss
    search(paper, [@work.merge("title" => paper.title)])
    enrich
    EnrichJournalPaperWorker.perform_one
    assert_nil paper.reload.openalex_id
    assert_equal "not_found", JournalPaperEnrichment.sole.status
    assert_in_delta 7.days.from_now.to_f, JournalPaperEnrichment.sole.next_attempt_at.to_f, 2
  end

  test "ambiguous and incomplete publisher search results cannot enrich a paper" do
    paper = import_mloss
    work = @work.merge("doi" => nil, "primary_location" => { "landing_page_url" => paper.urls.first })
    search(paper, [work, work.merge("id" => "https://openalex.org/W999")])
    enrich
    EnrichJournalPaperWorker.perform_one
    record = JournalPaperEnrichment.sole
    assert_equal "conflict", record.status
    assert_match "Multiple", record.last_error
    assert_nil paper.reload.openalex_id

    travel_to record.next_attempt_at + 1.second do
      search(paper, [work], count: 101)
      enrich
      EnrichJournalPaperWorker.perform_one
      assert_equal "conflict", record.reload.status
      assert_match "incomplete", record.last_error
      assert_nil paper.reload.openalex_id
    end
  end

  test "missing OpenAlex records are retried weekly without removing publication metadata" do
    paper = jss_paper
    original = paper.attributes
    request = lookup(status: 404)
    enrich
    EnrichJournalPaperWorker.perform_one
    record = JournalPaperEnrichment.sole
    assert_equal "not_found", record.status
    assert_equal original, paper.reload.attributes
    assert_equal 0, enrich.fetch("queued")
    assert_requested request, times: 1
    travel_to record.next_attempt_at + 1.second do
      lookup
      enrich
      EnrichJournalPaperWorker.perform_one
      assert_equal "ok", record.reload.status
    end
  end

  test "rate limits persist a shared cooldown for queued and future journal enrichment jobs" do
    jss_paper
    jss_paper(2)
    request = lookup(status: 429, headers: { "Retry-After" => "7200" })
    Faraday::Retry::Middleware.any_instance.expects(:sleep).never
    assert_equal 2, enrich.fetch("queued")
    EnrichJournalPaperWorker.perform_one
    EnrichJournalPaperWorker.perform_one
    record = JournalPaperEnrichment.find_by!(status: "rate_limited")
    assert_in_delta 2.hours.from_now.to_f, record.next_attempt_at.to_f, 2
    assert_equal "pending", JournalPaperEnrichment.where.not(id: record.id).sole.status
    result = enrich
    assert_equal "cooldown", result.fetch("status")
    assert_equal 0, result.fetch("queued")
    assert_requested request, times: 1
    assert_not_requested :get, "https://api.openalex.org/works/doi:10.18637/jss.v117.i02", query: { api_key: "test-key" }
    travel_to record.next_attempt_at + 1.second do
      assert_equal 2, enrich.fetch("queued")
    end
  end

  test "network failures preserve the last successful OpenAlex data and retry after an hour" do
    paper = jss_paper
    lookup
    enrich
    EnrichJournalPaperWorker.perform_one
    record = JournalPaperEnrichment.sole
    stub_request(:get, "https://api.openalex.org/works/W12345678").with(query: { api_key: "test-key" }).to_timeout
    travel_to record.next_attempt_at + 1.second do
      enrich
      EnrichJournalPaperWorker.perform_one
      assert_equal "error", record.reload.status
      assert_in_delta 1.hour.from_now.to_f, record.next_attempt_at.to_f, 1
      assert_equal @work, paper.reload.openalex_data
    end
  end

  test "conflicting DOI and existing paper identities cannot change or duplicate papers" do
    paper = jss_paper
    original = paper.attributes
    lookup(work: @work.merge("doi" => "https://doi.org/10.1234/other"))
    enrich
    EnrichJournalPaperWorker.perform_one
    record = JournalPaperEnrichment.sole
    assert_equal "conflict", record.status
    assert_equal original, paper.reload.attributes
    other = Paper.create!(title: "Other record", openalex_id: @work["id"])
    travel_to record.next_attempt_at + 1.second do
      lookup
      enrich
      assert_no_difference "Paper.count" do
        EnrichJournalPaperWorker.perform_one
      end
      assert_equal "conflict", record.reload.status
      assert_equal original, paper.reload.attributes
      assert_equal "Other record", other.reload.title
    end
  end

  test "scheduled batches only enroll journal papers and honor the configured limit" do
    7.times { |number| jss_paper(number + 1) }
    unrelated = Paper.create!(title: "Other paper", doi: "10.1234/unrelated")
    assert_equal 5, enrich.fetch("queued")
    assert_equal 5, JournalPaperEnrichment.count
    assert_equal 5, EnrichJournalPaperWorker.jobs.size
    assert_not JournalPaperEnrichment.exists?(paper_id: unrelated.id)
    assert_not_requested :any, /openalex/
  end

  test "queue failures leave enrollment available for the next scheduled run" do
    jss_paper
    EnrichJournalPaperWorker.stubs(:perform_async).raises(RedisClient::CannotConnectError)
    assert_raises(RedisClient::CannotConnectError) { enrich }
    assert_nil JournalPaperEnrichment.sole.lease_token
    EnrichJournalPaperWorker.unstub(:perform_async)
    assert_equal 1, enrich.fetch("queued")
  end

  test "expired leases are recovered and active leases prevent duplicate requests" do
    jss_paper
    lookup
    enrich
    record = JournalPaperEnrichment.sole
    record.update!(lease_token: "interrupted", lease_expires_at: 10.minutes.from_now)
    EnrichJournalPaperWorker.perform_one
    assert_nil record.reload.checked_at
    assert_equal 0, enrich.fetch("queued")
    assert_not_requested :any, /openalex/
    travel_to record.lease_expires_at + 1.second do
      assert_equal 1, enrich.fetch("queued")
      EnrichJournalPaperWorker.perform_one
      assert_equal "ok", record.reload.status
      assert_nil record.lease_token
    end
  end

  test "an obsolete worker cannot overwrite the result of a newer lease" do
    paper = jss_paper
    enrich
    record = JournalPaperEnrichment.sole
    stub_request(:get, "https://api.openalex.org/works/doi:10.18637/jss.v117.i01").with(query: { api_key: "test-key" })
      .to_return do
        record.update!(lease_token: "replacement", lease_expires_at: 10.minutes.from_now)
        { body: @work.to_json }
      end
    EnrichJournalPaperWorker.perform_one
    assert_nil paper.reload.openalex_id
    assert_equal "replacement", record.reload.lease_token
    assert_nil record.checked_at
  end

  test "missing API keys and invalid limits do not start enrichment" do
    jss_paper
    ENV.delete("OPENALEX_API_KEY")
    assert_equal({ "queued" => 0, "status" => "unconfigured" }, enrich)
    assert_empty JournalPaperEnrichment.all
    ENV["LIMIT"] = "26"
    assert_raises(ArgumentError) { enrich }
  end
end
