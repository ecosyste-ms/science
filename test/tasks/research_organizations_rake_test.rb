require "test_helper"
require "rake"
require "tmpdir"
require "open3"
require "digest/md5"

class ResearchOrganizationsRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[JSON_FILE VERSION MINIMUM_RECORDS BATCHES LIMIT RESTART OWNER_ID].freeze
  JHU = "https://ror.org/00za53h95"
  LAB = "https://ror.org/029pp9z10"
  OTHER = "https://ror.org/02wt5sv47"
  CICE = "https://ror.org/040g91402"

  setup do
    @env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV["MINIMUM_RECORDS"] = "1"
    @directory = Dir.mktmpdir("science-ror-test")
    @host = Host.create!(name: "GitHub")
    @record = JSON.parse(Rails.root.join("test/fixtures/files/ror_johns_hopkins.json").read)
    Rails.application.load_tasks unless Rake::Task.task_defined?("research_organizations:import_ror")
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  teardown do
    ENV_KEYS.each { |key| ENV.delete(key) }
    @env.each { |key, value| ENV[key] = value }
    FileUtils.remove_entry(@directory)
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "backfill matches a real ROR forge link without an owner website and exposes its evidence" do
    owner = Owner.create!(host: @host, login: "cice-consortium", kind: "organization")
    project = Project.create!(url: "https://github.com/cice-consortium/CICE", owner_record: owner, science_score: 42)
    original = project.attributes
    import_records([JSON.parse(Rails.root.join("test/fixtures/files/ror_cice_consortium.json").read)])
    run_task("backfill")
    link = owner.owner_research_organizations.confirmed.sole
    assert_equal CICE, link.research_organization.ror_id
    assert_equal "ror_forge_url", link.match_method
    assert_equal "github.com", link.evidence.fetch("host")
    assert_equal "cice-consortium", link.evidence.fetch("owner_login")
    assert_equal ["https://github.com/CICE-Consortium"], link.evidence.fetch("matched_urls")
    assert_equal "first", link.evidence.fetch("source_version")
    assert_nil owner.reload.institutional_domain
    assert_equal original, project.reload.attributes
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get("/api/v1/research_organizations/040g91402/owners")
    assert_equal 200, session.response.status
    entry = JSON.parse(session.response.body).sole
    assert_equal owner.id, entry.fetch("id")
    assert_equal "ror_forge_url", entry.fetch("organization_matches").sole.fetch("match_method")
    assert_equal link.evidence, entry.fetch("organization_matches").sole.fetch("evidence")
    session.get("/research-organizations/040g91402/owners")
    assert_equal 200, session.response.status
    assert_includes session.response.body, 'href="https://github.com/CICE-Consortium"'
  end

  test "backfill ignores unrelated account paths shared forge roots and other link types" do
    urls = ["https://github.com", "https://github.com/", "https://github.com/cice-consortium-other",
      "https://github.com/cice-consortium/repository", "https://github.com/orgs/cice-consortium/repositories",
      "https://notgithub.com/cice-consortium", "https://github.com.example.org/cice-consortium",
      "https://github.com:8443/cice-consortium", "https://user@github.com/cice-consortium",
      "https://example.org/?next=https://github.com/cice-consortium", "https://cice-consortium.github.io"]
    records = [record(JHU, domains: [], links: urls.map { |url| { "type" => "website", "value" => url } }),
      record(LAB, domains: [], links: [{ "type" => "wikipedia", "value" => "https://github.com/cice-consortium" }])]
    owner = Owner.create!(host: @host, login: "cice-consortium", kind: "organization")
    import_records(records)
    run_task("backfill")
    assert_empty owner.owner_research_organizations
  end

  test "backfill resumes past owners without hosts and preserves domain matches" do
    first = Owner.create!(host: @host, login: "first", kind: "organization", website: "https://jhu.edu")
    domain_owner = Owner.create!(host: @host, login: "domain-only", kind: "organization", website: "https://jhu.edu")
    unmatched = Owner.create!(host: @host, login: "no-host", kind: "organization")
    last = Owner.create!(host: @host, login: "jhu", kind: "organization")
    domain_owner.update_column(:host_id, nil)
    unmatched.update_column(:host_id, nil)
    import_records([record(JHU, links: [{ "type" => "website", "value" => "https://github.com/jhu" }])])

    ENV["LIMIT"] = "1"
    ENV["BATCHES"] = "1"
    assert_equal first.id, run_task("backfill").fetch("owner_cursor")
    ENV.delete("BATCHES")
    result = run_task("backfill")

    assert result.fetch("backfill_complete")
    assert_equal({ "matched" => 3, "unmatched" => 1 }, result.fetch("owner_counts"))
    assert_equal last.id, ResearchOrganizationImport.find_by!(current: true).owner_cursor
    assert_equal "ror_domain", domain_owner.owner_research_organizations.confirmed.sole.match_method
    assert_empty unmatched.owner_research_organizations
    assert_equal "ror_forge_url", last.owner_research_organizations.confirmed.sole.match_method
  end

  test "GitLab groups Codeberg accounts and self-hosted forge paths match the correct host" do
    gitlab = Host.create!(name: "GitLab", kind: "gitlab", url: "https://gitlab.com")
    codeberg = Host.create!(name: "codeberg.org", kind: "gitea", url: "https://codeberg.org")
    self_hosted = Host.create!(name: "git.example.org", kind: "gitlab", url: "https://git.example.org:8443/forge")
    owners = [Owner.create!(host: gitlab, login: "My-Org/lab", kind: "organization"),
      Owner.create!(host: codeberg, login: "My-Org", kind: "organization"),
      Owner.create!(host: self_hosted, login: "My-Org/lab", kind: "organization")]
    wrong_host = Owner.create!(host: @host, login: "My-Org", kind: "organization")
    urls = ["https://GITLAB.com/groups/my-org/lab/?view=projects", "http://codeberg.org/my-org#readme",
      "https://git.example.org:8443/forge/groups/my-org/lab"]
    import_records([JHU, LAB, OTHER].zip(urls).map { |id, url| record(id, domains: [], links: [{ "type" => "website", "value" => url }]) })
    run_task("backfill")
    owners.zip([JHU, LAB, OTHER], urls).each do |owner, id, url|
      link = owner.owner_research_organizations.confirmed.sole
      assert_equal id, link.research_organization.ror_id
      assert_equal [url], link.evidence.fetch("matched_urls")
    end
    assert_empty wrong_host.owner_research_organizations
  end

  test "forge links remain ambiguous when institutions share an account or domain evidence conflicts" do
    url = { "type" => "website", "value" => "https://github.com/shared" }
    owner = Owner.create!(host: @host, login: "shared", kind: "organization", website: "https://jhu.edu")
    import_records([@record, record(LAB, domains: [], links: [url]), record(OTHER, domains: [], links: [url])])
    run_task("backfill")
    assert_equal 3, owner.owner_research_organizations.count
    assert_equal ["ambiguous"], owner.owner_research_organizations.distinct.pluck(:match_status)
    assert_empty owner.owner_research_organizations.confirmed
    assert_equal "ror_domain", owner.owner_research_organizations.find_by!(research_organization: ResearchOrganization.find_by!(ror_id: JHU)).match_method
    owner.set_research_organization!(ResearchOrganization.find_by!(ror_id: LAB), evidence: { "confirmed_by" => "institution" })
    ENV["RESTART"] = "true"
    run_task("backfill")
    assert_equal ["manual"], owner.owner_research_organizations.confirmed.pluck(:source)
    assert_equal ["superseded"], owner.owner_research_organizations.where(source: "ror").distinct.pluck(:match_status)
  end

  test "forge and domain evidence for one institution produce one confirmed association" do
    owner = Owner.create!(host: @host, login: "jhu", kind: "organization", website: "https://jhu.edu")
    import_records([record(JHU, links: [{ "type" => "website", "value" => "https://github.com/jhu" }])])
    run_task("backfill")
    link = owner.owner_research_organizations.confirmed.sole
    assert_equal "ror_forge_url", link.match_method
    assert_equal "jhu.edu", link.evidence.fetch("matched_domain")
    assert_equal ["https://github.com/jhu"], link.evidence.fetch("matched_urls")
    before = link.attributes
    ENV["RESTART"] = "true"
    run_task("backfill")
    assert_equal before, link.reload.attributes
  end

  test "account identity changes refresh forge links without changing the website" do
    import_records([record(JHU, domains: [], links: [{ "type" => "website", "value" => "https://github.com/renamed" }])])
    owner = Owner.create!(host: @host, login: "original", kind: "organization")
    assert_empty owner.owner_research_organizations
    owner.update!(login: "ReNamed")
    assert_equal "ror_forge_url", owner.owner_research_organizations.confirmed.sole.match_method
    owner.update!(host: Host.create!(name: "Codeberg", url: "https://codeberg.org"))
    assert_empty owner.owner_research_organizations.confirmed
    assert_equal "superseded", owner.owner_research_organizations.sole.match_status
    owner.update!(host: @host)
    assert_equal "matched", owner.owner_research_organizations.sole.match_status
    owner.update!(hidden: true)
    assert_equal "superseded", owner.owner_research_organizations.sole.match_status
  end

  test "backfill restarts completed releases and matches only current active organization records" do
    owner = Owner.create!(host: @host, login: "forge", kind: "organization")
    user = Owner.create!(host: @host, login: "person", kind: "user")
    hidden = Owner.create!(host: @host, login: "hidden", kind: "organization", hidden: true)
    url = { "type" => "website", "value" => "https://github.com/forge" }
    import_records([record(JHU, domains: [], links: [url])])
    ResearchOrganizationForgeMatcher.stubs(:call).returns([])
    run_task("backfill")
    ResearchOrganizationForgeMatcher.unstub(:call)
    run_task("backfill")
    assert_empty owner.owner_research_organizations
    ENV["RESTART"] = "true"
    run_task("backfill")
    assert_equal "matched", owner.owner_research_organizations.sole.match_status
    import_records([record(JHU, domains: [], links: [url], status: "inactive"),
      record(LAB, domains: [], links: [{ "type" => "website", "value" => "https://github.com/person" }]),
      record(OTHER, domains: [], links: [{ "type" => "website", "value" => "https://github.com/hidden" }])], version: "second")
    ENV.delete("RESTART")
    run_task("backfill")
    assert_equal "superseded", owner.owner_research_organizations.sole.match_status
    assert_empty user.owner_research_organizations
    assert_empty hidden.owner_research_organizations
    import_records([record(LAB, domains: [], links: [])], version: "third")
    run_task("backfill")
    assert_empty owner.owner_research_organizations.confirmed
  end

  test "archive import retains full records and owner backfill leaves existing projects and scores intact" do
    create_research_organization_domain("jhu.edu", source: "ror", external_id: JHU)
    owner = Owner.create!(host: @host, login: "jhu", kind: "organization", website: "https://www.jhu.edu")
    project = Project.create!(url: "https://github.com/jhu/research", owner_record: owner,
      science_score: 42, science_score_breakdown: { "score" => 42 })
    original = project.attributes
    original_owner = owner.attributes
    no_domain = record(OTHER, domains: [], links: [], status: "inactive")
    no_domain["locations"] << { "geonames_details" => { "country_code" => "FR", "country_name" => "France" } }
    withdrawn = record(LAB, domains: [], links: [], status: "withdrawn")
    stub_archive([@record, no_domain, withdrawn])

    assert run_task("import_ror").fetch("complete")
    assert_equal 3, ResearchOrganization.available.count
    organization = ResearchOrganization.find_by!(ror_id: JHU)
    assert_equal @record, organization.metadata
    assert_equal ["US"], organization.country_codes
    assert_equal ["US", "FR"], ResearchOrganization.find_by!(ror_id: OTHER).country_codes
    assert_empty ResearchOrganization.find_by!(ror_id: OTHER).matching_domains
    assert run_task("backfill").fetch("backfill_complete")
    assert_equal original, project.reload.attributes
    assert_equal original_owner, owner.reload.attributes
    assert_equal 0, ExternalProjectSync.count
    assert_equal 1, owner.owner_research_organizations.count
    ENV["OWNER_ID"] = owner.id.to_s
    evidence = run_task("owner_links").sole
    assert_equal JHU, evidence.fetch("ror_id")
    assert_equal ["US"], evidence.fetch("country_codes")
    assert_equal "matched", evidence.fetch("match_status")
    assert_equal "repository_owner", evidence.fetch("relationship")
    assert_equal "jhu.edu", evidence.fetch("evidence").fetch("matched_domain")
    assert_equal "20260922", organization.current_import.source_version
    assert_equal "ror-data.zip", organization.current_import.source_metadata.fetch("filename")
  end

  test "shared domains retain ambiguous candidates and manual corrections survive refreshed releases" do
    owner = Owner.create!(host: @host, login: "shared", kind: "organization", website: "https://jhu.edu")
    import_records([@record, record(OTHER)])
    run_task("backfill")
    assert_equal ["ambiguous", "ambiguous"], owner.owner_research_organizations.order(:id).pluck(:match_status)
    assert_empty owner.owner_research_organizations.confirmed
    organization = ResearchOrganization.find_by!(ror_id: JHU)
    owner.set_research_organization!(organization, evidence: { "confirmed_by" => "institution administrator" })
    updated = @record.deep_dup
    updated["names"].find { |name| name["types"].include?("ror_display") }["value"] = "Updated university name"
    import_records([updated, record(OTHER)], version: "second")
    run_task("backfill")

    assert_equal organization.id, ResearchOrganization.find_by!(ror_id: JHU).id
    assert_equal "Updated university name", organization.reload.display_name
    assert_equal ["manual"], owner.owner_research_organizations.confirmed.pluck(:source)
    assert_equal "institution administrator", owner.owner_research_organizations.confirmed.sole.evidence.fetch("confirmed_by")
    assert_equal 2, owner.owner_research_organizations.where(source: "ror", match_status: "superseded").count
    assert_equal({ "manual" => 1 }, ResearchOrganizationImport.find_by!(current: true).owner_counts)
  end

  test "backfill resumes saved batches and a deliberate restart can revisit repaired accounts" do
    owners = 3.times.map do |index|
      Owner.create!(host: @host, login: "jhu-#{index}", kind: "organization", website: "https://jhu.edu")
    end
    import_records([@record])
    ENV["LIMIT"] = "1"
    ENV["BATCHES"] = "1"
    first = run_task("backfill")
    assert_equal owners.first.id, first.fetch("owner_cursor")
    assert_equal({ "matched" => 1 }, first.fetch("owner_counts"))
    first_link = owners.first.owner_research_organizations.sole.attributes
    run_task("backfill")
    assert_empty owners.last.owner_research_organizations
    ENV.delete("BATCHES")
    final = run_task("backfill")
    assert final.fetch("backfill_complete")
    assert_equal({ "matched" => 3 }, final.fetch("owner_counts"))
    assert_equal first_link, owners.first.owner_research_organizations.sole.attributes
    assert_no_difference("OwnerResearchOrganization.count") { run_task("backfill") }
    ENV["RESTART"] = "true"
    assert_equal({ "matched" => 3 }, run_task("backfill").fetch("owner_counts"))
    assert_equal first_link, owners.first.owner_research_organizations.sole.attributes
  end

  test "normal owner saves repair associations and retain previous match evidence" do
    import_records([@record, record(OTHER, domains: ["other.edu"])])
    owner = Owner.create!(host: @host, login: "jhu", kind: "organization", website: "https://jhu.edu")
    old = owner.owner_research_organizations.sole
    assert_equal "matched", old.match_status
    owner.update!(website: "https://other.edu")
    assert_equal "superseded", old.reload.match_status
    assert_equal "jhu.edu", old.evidence.fetch("matched_domain")
    assert_equal [OTHER], owner.owner_research_organizations.confirmed.joins(:research_organization).pluck("research_organizations.ror_id")
    owner.update!(website: "https://unknown.edu")
    assert_empty owner.owner_research_organizations.confirmed
    assert_equal 2, owner.owner_research_organizations.count
  end

  test "domain matching respects label boundaries website fallback and hidden owners" do
    owners = %w[lab.jhu.edu notjhu.edu unknown.edu].map.with_index do |domain, index|
      Owner.create!(host: @host, login: "owner-#{index}", kind: "organization", website: "https://#{domain}")
    end
    hidden = Owner.create!(host: @host, login: "hidden", kind: "organization", website: "https://jhu.edu", hidden: true)
    root = Owner.create!(host: @host, login: "root", kind: "organization", website: "https://root.edu")
    fallback = record(OTHER, domains: [], links: [{ "type" => "website", "value" => "https://root.edu/" }])
    import_records([@record, fallback])
    outcomes = run_task("backfill").fetch("owner_counts")
    assert_equal({ "matched" => 2, "unmatched" => 2 }, outcomes)
    assert_equal JHU, owners.first.owner_research_organizations.sole.research_organization.ror_id
    assert_empty owners[1].owner_research_organizations
    assert_empty owners[2].owner_research_organizations
    assert_equal "ror_website", root.owner_research_organizations.sole.match_method
    assert_empty hidden.owner_research_organizations
    ENV["OWNER_ID"] = hidden.id.to_s
    assert_raises(ActiveRecord::RecordNotFound) { run_task("owner_links") }
  end

  test "relationships deduplicate reciprocals and traverse multiple parents and cycles without related or successor nodes" do
    fourth = "https://ror.org/00gzx6s15"
    fifth = "https://ror.org/05hs7zv85"
    records = [
      record(JHU, relationships: [relation(LAB, "child"), relation(OTHER, "child"), relation(fourth, "related"), relation(fifth, "successor")]),
      record(LAB, relationships: [relation(JHU, "parent"), relation(OTHER, "child")]),
      record(OTHER, relationships: [relation(JHU, "parent"), relation(LAB, "parent"), relation(JHU, "child")]),
      record(fourth, relationships: [relation(JHU, "related")]),
      record(fifth, relationships: [relation(JHU, "predecessor")]),
    ]
    import_records(records)
    organization = ResearchOrganization.find_by!(ror_id: JHU)
    assert_equal [LAB, OTHER].sort, organization.descendants.pluck(:ror_id).sort
    assert_equal 4, ResearchOrganizationRelationship.where(kind: "child").count
    assert_equal 1, ResearchOrganizationRelationship.where(kind: "related").count
    assert_equal 1, ResearchOrganizationRelationship.where(kind: "successor").count
  end

  test "a failed staged release preserves current metadata and can resume after interruption" do
    import_records([@record], version: "first")
    organization = ResearchOrganization.find_by!(ror_id: JHU)
    records = 1_001.times.map do |index|
      record(format("https://ror.org/0%06d01", index), domains: [], links: [], relationships: [])
    end
    ENV["BATCHES"] = "1"
    partial = import_records(records, version: "second")
    assert_equal 1_000, partial.fetch("records_processed")
    assert_not partial.fetch("complete")
    assert_equal @record, organization.reload.metadata
    assert_equal "first", ResearchOrganizationImport.find_by!(current: true).source_version
    assert_equal 1, ResearchOrganization.available.count
    ENV.delete("BATCHES")
    assert run_task("import_ror").fetch("complete")
    assert_equal 1_001, ResearchOrganization.current.count
    assert_equal 1_002, ResearchOrganization.available.count
    assert_not organization.reload.current_import.current?
  end

  test "truncated JSON and invalid records do not replace the usable catalogue" do
    import_records([@record], version: "first")
    path = File.join(@directory, "broken.json")
    File.write(path, "[#{record(OTHER).to_json},")
    ENV["JSON_FILE"] = path
    ENV["VERSION"] = "broken"
    assert_raises(ArgumentError) { run_task("import_ror") }
    assert_equal "first", ResearchOrganizationImport.find_by!(current: true).source_version
    assert_equal 1, ResearchOrganization.available.count
    assert_match "Incomplete", ResearchOrganizationImport.find_by!(source_version: "broken").last_error
    assert_nil ResearchOrganizationImport.find_by!(source_version: "broken").lease_token
  end

  test "a changed file cannot silently continue a saved import" do
    records = 1_001.times.map { |index| record(format("https://ror.org/0%06d01", index), relationships: []) }
    ENV["BATCHES"] = "1"
    import_records(records)
    File.write(ENV.fetch("JSON_FILE"), [@record].to_json)
    assert_raises(ArgumentError) { run_task("import_ror") }
    assert_equal 1_000, ResearchOrganizationImport.sole.records_processed
    assert_empty ResearchOrganization.available
  end

  test "archive checksum failures leave the prior catalogue untouched" do
    import_records([@record])
    ENV.delete("JSON_FILE")
    stub_archive([record(OTHER)], version: 20261001, checksum: "md5:#{'0' * 32}")
    assert_raises(RuntimeError) { run_task("import_ror") }
    assert_equal "first", ResearchOrganizationImport.find_by!(current: true).source_version
    assert_equal 1, ResearchOrganization.count
  end

  test "reader preserves unicode and escaped braces across chunks and rejects trailing commas" do
    changed = @record.deep_dup
    changed["names"][0]["value"] = "é\\\"{}" * 20_000
    import_records([changed])
    assert_equal changed, ResearchOrganization.sole.metadata
    path = File.join(@directory, "comma.json")
    File.write(path, "[#{@record.to_json},]")
    ENV["JSON_FILE"] = path
    ENV["VERSION"] = "comma"
    assert_raises(ArgumentError) { run_task("import_ror") }
    assert_equal changed, ResearchOrganization.sole.reload.metadata
  end

  def run_task(name)
    task = Rake::Task["research_organizations:#{name}"]
    task.reenable
    output, = capture_io { task.invoke }
    JSON.parse(output.lines.last)
  end

  def record(id, **changes)
    @record.deep_dup.merge("id" => id, "relationships" => []).merge(changes.transform_keys(&:to_s))
  end

  def relation(id, type)
    { "id" => id, "type" => type, "label" => "Research organization" }
  end

  def import_records(records, version: "first")
    path = File.join(@directory, "#{version}.json")
    File.write(path, records.to_json)
    ENV["JSON_FILE"] = path
    ENV["VERSION"] = version
    run_task("import_ror")
  end

  def stub_archive(records, version: 20260922, checksum: nil)
    source = File.join(@directory, "ror.json")
    archive = File.join(@directory, "ror-data.zip")
    File.write(source, records.to_json)
    _, error, status = Open3.capture3("bsdtar", "-a", "-cf", archive, "-C", @directory, "ror.json")
    raise error unless status.success?
    metadata = { "id" => version, "doi" => "10.5281/zenodo.#{version}",
      "metadata" => { "publication_date" => "2026-09-22" },
      "files" => [{ "key" => "ror-data.zip", "checksum" => checksum || "md5:#{Digest::MD5.file(archive).hexdigest}",
        "links" => { "self" => "https://zenodo.org/api/files/ror-test/ror-data.zip" } }] }
    stub_request(:get, RorResearchOrganizationDomainImporter::ZENODO_RECORD_URL).to_return(body: metadata.to_json)
    stub_request(:get, "https://zenodo.org/api/files/ror-test/ror-data.zip").to_return(body: File.binread(archive))
  end
end
