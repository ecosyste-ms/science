require "test_helper"
require_relative "../support/software_doi_pipeline"

class SyncSoftwareDoiWorkerTest < ActiveSupport::TestCase
  include SoftwareDoiPipeline

  test "worker matches a normalized software DOI without repository links and preserves raw metadata and scores" do
    id = "10.6084/m9.figshare.9577868"
    project = doi_project(doi: id)
    before = project.attributes
    request = datacite_record(id)
    assert_no_difference "Project.count" do
      sync_dois(["https://doi.org/#{id.upcase}", "doi:#{id}"])
    end
    record = project.external_software_records.sole
    assert_equal "ok", record.status
    assert_equal id, record.identifier
    assert_equal @datacite[id], record.metadata["datacite"]
    assert_equal before, project.reload.attributes
    link = project.project_external_software_records.sole
    assert_equal "software", link.relationship
    assert_equal "software_doi", link.evidence.sole["match_method"]
    assert_equal "citation_cff.doi", link.evidence.sole["source_field"]
    assert_equal SoftwareDoiClient.collection_url(id), record.collection_url
    sync_dois([id])
    assert_requested request, times: 1
  end

  test "Zenodo adds a repository absent in DataCite while aliases and DOI routes deduplicate the project" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(url: "https://github.com/new/eko", doi: id)
    project.repository_aliases.create!(url: "https://github.com/NNPDF/eko")
    doi_record(id)
    sync_dois([id])
    record = project.external_software_records.sole
    assert_equal @zenodo[id], record.metadata["zenodo"]
    assert_equal @datacite[id], record.metadata["datacite"]
    assert_equal "10.5281/zenodo.3874237", record.concept_identifier
    link = project.project_external_software_records.sole
    assert_equal "software_version", link.relationship
    assert_equal %w[repository_alias software_doi], link.evidence.pluck("match_method").sort
    assert_includes link.evidence.pluck("collection_url"), "https://zenodo.org/api/records/15878535"
    assert_equal 1, ProjectExternalSoftwareRecord.count
  end

  test "unclassified DataCite records are stored without software links and the batch continues" do
    id = "10.7488/era/4167"
    following = "10.6084/m9.figshare.9577868"
    project = doi_project(doi: id)
    following_project = doi_project(url: "https://github.com/example/following", doi: following)
    resource = JSON.parse(Rails.root.join("test/fixtures/files/software_doi_datacite_unclassified.json").read)
    datacite_record(id, body: { data: resource })
    datacite_record(following)

    sync_dois([id, following])

    record = ExternalSoftwareRecord.find_by!(source: "doi", identifier: id)
    assert_equal "ok", record.status
    assert_nil record.last_error
    assert_nil record.concept_identifier
    assert_equal resource, record.metadata["datacite"]
    assert_in_delta 30.days.from_now.to_f, record.next_refresh_at.to_f, 5
    assert_empty project.external_software_records
    assert_equal "ok", following_project.external_software_records.sole.status
    assert_empty SyncSoftwareDoiWorker.jobs
  end

  test "Zenodo software without a concept DOI retains metadata and links while the batch continues" do
    id = "10.5281/zenodo.546311"
    following = "10.6084/m9.figshare.9577868"
    project = doi_project(url: "https://github.com/FowlerLab/simdms", doi: id)
    resource = JSON.parse(Rails.root.join("test/fixtures/files/software_doi_datacite_without_concept.json").read)
    zenodo = JSON.parse(Rails.root.join("test/fixtures/files/software_doi_zenodo_without_concept.json").read)
    datacite_record(id, body: { data: resource })
    stub_request(:get, "https://zenodo.org/api/records/546311").to_return(body: zenodo.to_json)
    datacite_record(following)

    sync_dois([id, following])

    record = project.external_software_records.sole
    assert_equal "ok", record.status
    assert_nil record.last_error
    assert_nil record.concept_identifier
    assert_equal resource, record.metadata["datacite"]
    assert_equal zenodo, record.metadata["zenodo"]
    link = project.project_external_software_records.sole
    assert_equal "software", link.relationship
    assert_includes link.evidence.pluck("source_field"), "zenodo.metadata.related_identifiers"
    assert_equal "ok", ExternalSoftwareRecord.find_by!(source: "doi", identifier: following).status
    assert_empty SyncSoftwareDoiWorker.jobs
  end

  test "missing Zenodo concept DOIs do not establish DataCite version relationships" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(doi: id)
    [nil, "", :missing].each do |concept|
      expire_dois
      @zenodo[id]["conceptdoi"] = concept
      @zenodo[id].delete("conceptdoi") if concept == :missing
      doi_record(id)

      sync_dois([id])

      assert_equal "ok", project.external_software_records.sole.status
      assert_nil project.external_software_records.sole.concept_identifier
      assert_equal "software", project.project_external_software_records.sole.relationship
    end
  end

  test "malformed or mismatched Zenodo concept DOIs preserve successful evidence" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(doi: id)
    doi_record(id)
    sync_dois([id])
    record = project.external_software_records.sole
    before = record.attributes.slice("metadata", "retrieved_at", "concept_identifier")
    [false, [], {}, "invalid", "10.5281/zenodo.999"].each do |concept|
      expire_dois
      @zenodo[id]["conceptdoi"] = concept
      doi_record(id)

      assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }

      assert_equal "error", record.reload.status
      assert_equal before, record.attributes.slice(*before.keys)
      assert_equal "software_version", project.project_external_software_records.sole.relationship
    end
  end

  test "Zenodo concept redirects still require a matching concept DOI" do
    id = "10.5281/zenodo.596036"
    datacite_record(id)
    @zenodo["10.5281/zenodo.19636730"]["conceptdoi"] = ""
    stub_request(:get, "https://zenodo.org/api/records/596036")
      .to_return(status: 302, headers: { "Location" => "https://zenodo.org/api/records/19636730" })
    zenodo_record("10.5281/zenodo.19636730")

    assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }

    assert_equal "error", ExternalSoftwareRecord.find_by!(source: "doi", identifier: id).status
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "missing or null Zenodo classification does not fetch Zenodo or establish software links" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(doi: id)
    [nil, :missing].each do |classification|
      expire_dois
      types = @datacite[id]["attributes"]["types"]
      types["resourceTypeGeneral"] = classification
      types.delete("resourceTypeGeneral") if classification == :missing
      datacite_record(id)

      sync_dois([id])

      assert_equal "ok", ExternalSoftwareRecord.find_by!(source: "doi", identifier: id).status
      assert_empty project.external_software_records
    end
    assert_not_requested :any, /zenodo.org/
  end

  test "malformed DataCite classification remains an error" do
    id = "10.6084/m9.figshare.9577868"
    doi_project(doi: id)
    [false, 123, [], {}].each do |classification|
      expire_dois
      @datacite[id]["attributes"]["types"]["resourceTypeGeneral"] = classification
      datacite_record(id)

      assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }

      assert_equal "error", ExternalSoftwareRecord.find_by!(source: "doi", identifier: id).status
      assert_empty ProjectExternalSoftwareRecord.all
    end
  end

  test "publication and stale search seeds never establish software identity" do
    id = "10.6084/m9.figshare.9577868"
    projects = [
      doi_project(url: "https://github.com/example/cff", citation_file: "cff-version: 1.2.0\nmessage: Cite this software\ntitle: Software\nauthors:\n  - name: Research team\npreferred-citation:\n  type: article\n  title: Paper\n  authors:\n    - name: Research team\n  doi: #{id}\n"),
      doi_project(url: "https://github.com/example/code", codemeta: { referencePublication: { identifier: id } }.to_json),
      doi_project(url: "https://github.com/example/zenodo", zenodo: { related_identifiers: [{ scheme: "doi", relation: "isDocumentedBy", identifier: id }] }.to_json),
      doi_project(url: "https://github.com/example/dataset", citation_file: "cff-version: 1.2.0\nmessage: Cite this dataset\ntitle: Dataset\nauthors:\n  - name: Research team\ntype: dataset\ndoi: #{id}\n"),
      doi_project(url: "https://github.com/example/stale", doi: id)
    ]
    projects.last.update_columns(citation_file: nil)
    assert projects.all? { |project| project.search_identifiers["doi"].include?(id) }
    datacite_record(id)
    sync_dois([id])
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "nonsoftware classification removes prior links without fetching Zenodo" do
    id = "10.6084/m9.figshare.9577868"
    project = doi_project(doi: id)
    doi_record(id)
    sync_dois([id])
    expire_dois
    @datacite[id]["attributes"]["types"]["resourceTypeGeneral"] = "Dataset"
    datacite_record(id)
    sync_dois([id])
    assert_empty project.external_software_records
    doi_record("10.5281/zenodo.18366850")
    sync_dois(["10.5281/zenodo.18366850"])
    assert_not_requested :any, /zenodo.org/
  end

  test "related citations dependencies and homepages cannot link another repository" do
    id = "10.6084/m9.figshare.9577868"
    project = doi_project
    attributes = @datacite[id]["attributes"]
    attributes["relatedIdentifiers"] = %w[Cites References IsDocumentedBy Requires IsDerivedFrom].map do |relation|
      { "relatedIdentifier" => project.url, "relatedIdentifierType" => "URL", "relationType" => relation }
    end
    attributes["url"] = "https://example.org/tool"
    datacite_record(id)
    sync_dois([id])
    assert_empty project.external_software_records
    expire_dois
    attributes["relatedIdentifiers"] << { "relatedIdentifier" => "https://example.github.io/tool/docs/", "relatedIdentifierType" => "URL", "relationType" => "IsSupplementTo" }
    datacite_record(id)
    sync_dois([id])
    assert_equal "github_pages", project.project_external_software_records.sole.evidence.sole["url_transformation"]
  end

  test "shared software DOIs remain ambiguous and hidden projects cannot match" do
    id = "10.6084/m9.figshare.9577868"
    first = doi_project(doi: id)
    doi_project(url: "https://github.com/example/other", doi: id)
    hidden = doi_project(url: "https://github.com/example/hidden", doi: id, hidden: true)
    datacite_record(id)
    sync_dois([id])
    assert_equal 2, ProjectExternalSoftwareRecord.count
    assert_equal ["ambiguous"], ProjectExternalSoftwareRecord.distinct.pluck(:match_status)
    assert_empty first.project_external_software_records.registry_references
    assert_empty hidden.external_software_records
  end

  test "invalid responses retain successful evidence" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(doi: id)
    doi_record(id)
    sync_dois([id])
    saved = project.external_software_records.sole
    before = saved.attributes.slice("metadata", "retrieved_at", "collection_url", "concept_identifier")
    [{}, { data: @datacite["10.6084/m9.figshare.9577868"] }, { data: @datacite[id].merge("attributes" => {}) }].each do |body|
      expire_dois
      datacite_record(id, body: body)
      assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }
      assert_equal before, saved.reload.attributes.slice(*before.keys)
      assert_equal "error", saved.status
      assert_equal 1, project.project_external_software_records.registry_references.size
    end
    expire_dois
    datacite_record(id)
    stub_request(:get, "https://zenodo.org/api/records/15878535").to_return(status: 500, body: "unavailable")
    assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }
    assert_equal before, saved.reload.attributes.slice(*before.keys)
  end

  test "deposited DataCite relationships do not override the validated Zenodo concept" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(doi: id)
    @datacite[id]["attributes"]["relatedIdentifiers"] = [{ "relationType" => "IsVersionOf", "relatedIdentifierType" => "DOI", "relatedIdentifier" => "10.5281/zenodo.999" }]
    doi_record(id)

    sync_dois([id])

    record = project.external_software_records.sole
    assert_equal "ok", record.status
    assert_equal "10.5281/zenodo.3874237", record.concept_identifier
    assert_equal @datacite[id], record.metadata["datacite"]
    assert_equal "software_version", project.project_external_software_records.sole.relationship
  end

  test "blank and multiple deposited version relationships retain software records and repositories" do
    entities = JSON.parse(Rails.root.join("test/fixtures/files/software_doi_relationships.json").read)
    projects = [doi_project(url: "https://github.com/MUON-CFD/SOMAR"), doi_project(url: "https://github.com/rraadd88/beditor")]
    entities.each do |entity|
      datacite_record(entity["doi"], body: { data: entity["datacite"] })
      stub_request(:get, "https://zenodo.org/api/records/#{entity['zenodo']['id']}").to_return(body: entity["zenodo"].to_json)
    end

    sync_dois(entities.pluck("doi"))

    projects.zip(entities).each do |project, entity|
      record = project.external_software_records.sole
      assert_equal "ok", record.status
      assert_nil record.last_error
      assert_equal entity, record.metadata
      assert_in_delta 30.days.from_now.to_f, record.next_refresh_at.to_f, 5
    end
    assert_nil projects.first.external_software_records.sole.concept_identifier
    assert_equal "software", projects.first.project_external_software_records.sole.relationship
    assert_equal "10.5281/zenodo.10648263", projects.last.external_software_records.sole.concept_identifier
    assert_equal "software_version", projects.last.project_external_software_records.sole.relationship
  end

  test "unusable optional relationship collections preserve exact DOI matches and raw metadata" do
    id = "10.5281/zenodo.15878535"
    project = doi_project(doi: id)
    [nil, :missing, {}, "invalid", false].each do |relationships|
      expire_dois
      @datacite[id]["attributes"]["relatedIdentifiers"] = relationships
      @zenodo[id]["metadata"]["related_identifiers"] = relationships
      if relationships == :missing
        @datacite[id]["attributes"].delete("relatedIdentifiers")
        @zenodo[id]["metadata"].delete("related_identifiers")
      end
      doi_record(id)

      sync_dois([id])

      record = project.external_software_records.sole
      assert_equal "ok", record.status
      assert_equal @datacite[id], record.metadata["datacite"]
      assert_equal @zenodo[id], record.metadata["zenodo"]
      assert_equal "10.5281/zenodo.3874237", record.concept_identifier
    end
  end

  test "malformed relationship entries cannot supply links or hide valid relationships" do
    id = "10.5281/zenodo.15878535"
    datacite_project = doi_project(url: "https://github.com/example/datacite")
    zenodo_project = doi_project(url: "https://github.com/example/zenodo")
    unrelated = doi_project(url: "https://github.com/example/unrelated")
    @datacite[id]["attributes"]["relatedIdentifiers"] = [nil, false, [], "invalid", {},
      { "relatedIdentifier" => unrelated.url, "relatedIdentifierType" => [], "relationType" => "IsSupplementTo" },
      { "relatedIdentifier" => unrelated.url, "relatedIdentifierType" => "URL", "relationType" => nil },
      { "relatedIdentifier" => [], "relatedIdentifierType" => "URL", "relationType" => "IsSupplementTo" },
      { "relatedIdentifier" => "", "relatedIdentifierType" => "DOI", "relationType" => "IsVersionOf" },
      { "relatedIdentifier" => datacite_project.url, "relatedIdentifierType" => "URL", "relationType" => "IsSupplementTo" }]
    @zenodo[id]["metadata"]["related_identifiers"] = [nil, false, [], "invalid", {},
      { "identifier" => unrelated.url, "scheme" => [], "relation" => "isSupplementTo" },
      { "identifier" => unrelated.url, "scheme" => "url", "relation" => nil },
      { "identifier" => [], "scheme" => "url", "relation" => "isSupplementTo" },
      { "identifier" => zenodo_project.url, "scheme" => "url", "relation" => "isSupplementTo" }]
    doi_record(id)

    sync_dois([id])

    record = ExternalSoftwareRecord.find_by!(source: "doi", identifier: id)
    assert_equal "ok", record.status
    assert_equal @datacite[id], record.metadata["datacite"]
    assert_equal @zenodo[id], record.metadata["zenodo"]
    assert_equal [datacite_project.id, zenodo_project.id].sort, record.projects.pluck(:id).sort
    assert_empty unrelated.external_software_records
  end

  test "DataCite family inference ignores malformed and ambiguous DOI relationships" do
    id = "10.6084/m9.figshare.9577868"
    parent = "10.6084/m9.figshare.12345"
    project = doi_project(doi: id)
    malformed = [nil, {}, { "relationType" => "HasVersion" },
      { "relatedIdentifier" => "invalid", "relatedIdentifierType" => "DOI", "relationType" => "HasVersion" },
      { "relatedIdentifier" => "", "relatedIdentifierType" => "DOI", "relationType" => "IsVersionOf" }]
    version = { "relatedIdentifier" => parent, "relatedIdentifierType" => "DOI", "relationType" => "IsVersionOf" }
    [[malformed, nil, "software"],
      [malformed + [version], parent, "software_version"],
      [malformed + [version, version.merge("relatedIdentifier" => "10.6084/m9.figshare.67890")], nil, "software"],
      [malformed + [version.merge("relationType" => "HasVersion")], nil, "software_concept"]].each do |relations, concept, relationship|
      expire_dois
      @datacite[id]["attributes"]["relatedIdentifiers"] = relations
      datacite_record(id)

      sync_dois([id])

      record = project.external_software_records.sole
      assert_equal "ok", record.status
      concept ? assert_equal(concept, record.concept_identifier) : assert_nil(record.concept_identifier)
      assert_equal relationship, project.project_external_software_records.sole.relationship
    end
  end

  test "failed records preserve evidence and do not prevent the rest of the batch from syncing" do
    id = "10.5281/zenodo.15878535"
    following = "10.6084/m9.figshare.9577868"
    project = doi_project(doi: id)
    doi_record(id)
    sync_dois([id])
    saved = project.external_software_records.sole
    before = saved.attributes.slice("metadata", "retrieved_at", "concept_identifier")
    expire_dois
    datacite_record(id, body: {})
    following_request = datacite_record(following)

    error = assert_raises(SoftwareDoiClient::Error) { sync_dois([id, following]) }

    assert_equal "#{id}: Invalid DataCite DOI record", error.message
    assert_equal "error", saved.reload.status
    assert_equal error.message, saved.last_error
    assert_equal before, saved.attributes.slice(*before.keys)
    assert_equal 1, project.project_external_software_records.registry_references.size
    assert_equal "ok", ExternalSoftwareRecord.find_by!(source: "doi", identifier: following).status
    assert_requested following_request, times: 1
  end

  test "Zenodo redirects are restricted to matching published records on the same service" do
    id = "10.5281/zenodo.596036"
    datacite_record(id)
    ["https://example.org/api/records/19636730", "http://zenodo.org/api/records/19636730", "https://zenodo.org/api/records/19636730?key=x"].each do |location|
      expire_dois
      stub_request(:get, "https://zenodo.org/api/records/596036").to_return(status: 302, headers: { "Location" => location })
      assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }
    end
    expire_dois
    stub_request(:get, "https://zenodo.org/api/records/596036").to_return(body: @zenodo["10.5281/zenodo.15878535"].to_json)
    assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "confirmed missing DOIs hide references but generic errors preserve them" do
    id = "10.6084/m9.figshare.9577868"
    project = doi_project(doi: id)
    datacite_record(id)
    sync_dois([id])
    expire_dois
    datacite_record(id, status: 404, body: { message: "Not found" })
    assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }
    assert_equal 1, project.project_external_software_records.registry_references.size
    expire_dois
    datacite_record(id, status: 404, body: { errors: [{ status: "404", title: "The resource you are looking for doesn't exist." }] })
    sync_dois([id])
    assert_equal "missing", project.external_software_records.sole.status
    assert_equal @datacite[id], project.external_software_records.sole.metadata["datacite"]
    assert_empty project.project_external_software_records.registry_references
  end

  test "deleted Zenodo records hide references and preserve metadata while the batch continues" do
    id = "10.5281/zenodo.15878535"
    following = "10.6084/m9.figshare.9577868"
    project = doi_project(doi: id)
    doi_record(id)
    sync_dois([id])
    saved = project.external_software_records.sole
    before = saved.attributes.slice("metadata", "retrieved_at", "collection_url", "concept_identifier")
    expire_dois
    stub_request(:get, "https://zenodo.org/api/records/15878535")
      .to_return(status: 410, body: { status: 410, message: "Record deleted", tombstone: { is_visible: true } }.to_json)
    datacite_record(following)

    sync_dois([id, following])

    assert_equal "missing", saved.reload.status
    assert_nil saved.last_error
    assert_equal before, saved.attributes.slice(*before.keys)
    assert_in_delta 7.days.from_now.to_f, saved.next_refresh_at.to_f, 5
    assert_empty project.project_external_software_records.registry_references
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: following).status
    assert_empty SyncSoftwareDoiWorker.jobs
  end

  test "a new Zenodo concept redirected to a deleted record is stored as missing" do
    id = "10.5281/zenodo.596036"
    project = doi_project(doi: id)
    doi_record(id)
    stub_request(:get, "https://zenodo.org/api/records/19636730")
      .to_return(status: 410, body: { status: 410, message: "Record deleted" }.to_json)

    sync_dois([id])

    record = ExternalSoftwareRecord.find_by!(source: "doi", identifier: id)
    assert_equal "missing", record.status
    assert_nil record.last_error
    assert_nil record.retrieved_at
    assert_empty project.external_software_records
    assert_empty SyncSoftwareDoiWorker.jobs
  end

  test "rate limits retain partial batches and delay jobs with separate service cooldowns" do
    first = "10.6084/m9.figshare.9577868"
    second = "10.5281/zenodo.15878535"
    third = "10.5281/zenodo.596036"
    datacite_record(first)
    datacite_record(second)
    request = stub_request(:get, "https://zenodo.org/api/records/15878535").to_return(status: 429, headers: { "Retry-After" => "600" })
    sync_dois([first, second, third])
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: first).status
    assert_equal "error", ExternalSoftwareRecord.find_by!(identifier: second).status
    assert SyncSoftwareDoiWorker.jobs.sole["at"] >= 9.minutes.from_now.to_f
    assert_equal [[first, second, third]], SyncSoftwareDoiWorker.jobs.sole["args"]
    assert_not_requested :get, SoftwareDoiClient.collection_url(third)
    assert_raises(SoftwareDoiClient::RateLimited) { SoftwareDoiClient.new.record(second) }
    assert_equal first, SoftwareDoiClient.new.record(first)["doi"]
    assert_requested request, times: 1
  end

  test "invalid identifiers and oversized batches do not make requests" do
    [[], [1], ["10.1234/../../secrets"], ["bad"], ["10.1234/has space"], ["10.1234/a"] * 26].each do |ids|
      assert_raises(ArgumentError) { SyncSoftwareDoiWorker.new.perform(ids) }
    end
    assert_not_requested :any, /datacite.org|zenodo.org/
  end

  test "very broad DOI candidate sets fail without loading unbounded project metadata" do
    id = "10.6084/m9.figshare.9577868"
    Project.insert_all!(101.times.map do |index|
      { url: "https://github.com/example/tool-#{index}", science_score: 42, search_identifiers: { doi: [id] } }
    end)
    datacite_record(id)
    error = assert_raises(SoftwareDoiClient::Error) { sync_dois([id]) }
    assert_equal "#{id}: DOI has more than 100 candidate projects", error.message
    assert_equal "error", ExternalSoftwareRecord.sole.status
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "known DOI enrichment cannot enable new repository discovery" do
    id = "10.5281/zenodo.15878535"
    doi_record(id)
    assert_no_difference "Project.count" do
      sync_dois([id])
      result = DiscoverExternalRepositoriesWorker.new.perform(100)
      assert_equal 0, result[:processed]
    end
    assert_equal "ok", ExternalSoftwareRecord.sole.status
  end
end
