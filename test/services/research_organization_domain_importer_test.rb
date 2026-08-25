require "test_helper"
require "stringio"

class ResearchOrganizationDomainImporterTest < ActiveSupport::TestCase
  ROR_CSV = <<~CSV
    id,status,types,domains,names.types.ror_display
    https://ror.org/inbo,active,facility,inbo.be,Research Institute for Nature and Forest
    https://ror.org/company,active,company,microsoft.com,Microsoft
    https://ror.org/government,active,government,gov.uk,UK Government
    https://ror.org/inactive,inactive,education,inactive.edu,Inactive University
  CSV

  def teardown
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "manual import stores the former code domains as active rows" do
    result = ManualResearchOrganizationDomainImporter.sync!

    assert result[:imported]
    assert ResearchOrganizationDomain.active.where(source: "manual").exists?(domain: "nasa.gov")
    assert ResearchOrganizationDomain.active.where(source: "manual").exists?(domain: "ac.uk")
    assert_not ManualResearchOrganizationDomainImporter.sync![:imported]
  end

  test "ROR import assigns strengths and rejects public suffixes" do
    result = RorResearchOrganizationDomainImporter.import_csv!(
      StringIO.new(ROR_CSV),
      version: "123",
      published_at: "2026-08-03",
      minimum_domains: 1
    )

    domains = ResearchOrganizationDomain.active.where(source: "ror").index_by(&:domain)
    assert_equal %w[inbo.be microsoft.com], domains.keys.sort
    assert_equal 1.0, domains.fetch("inbo.be").strength
    assert_equal 0.4, domains.fetch("microsoft.com").strength
    assert_equal 1, result[:rejected_public_suffixes]
  end

  test "sync enters through Zenodo metadata and archive processing" do
    metadata = {
      "id" => 123,
      "doi" => "10.5281/zenodo.123",
      "metadata" => { "publication_date" => "2026-08-03" },
      "files" => [{
        "key" => "ror-data.zip",
        "checksum" => "md5:d41d8cd98f00b204e9800998ecf8427e",
        "links" => { "self" => "https://zenodo.org/files/ror-data.zip" },
      }],
    }
    RorResearchOrganizationDomainImporter.stubs(:fetch_metadata).returns(metadata)
    RorResearchOrganizationDomainImporter.stubs(:download_archive)
    RorResearchOrganizationDomainImporter.stubs(:verify_checksum!)
    RorResearchOrganizationDomainImporter.stubs(:open_csv).yields(StringIO.new(ROR_CSV))

    result = RorResearchOrganizationDomainImporter.sync!(minimum_domains: 1)

    assert result[:imported]
    assert_equal "123", result[:version]
    assert_equal 2, result[:domains]
  end

  test "refresh reclassifies owners when the first ROR download fails" do
    manual = ManualResearchOrganizationDomainImporter.sync!
    ManualResearchOrganizationDomainImporter.stubs(:sync!).returns(manual)
    RorResearchOrganizationDomainImporter.stubs(:sync!).raises("download failed")
    Owner.expects(:reclassify_research_organizations!).once.returns(processed: 0)

    assert_raises(RuntimeError) { ResearchOrganizationDomainRefresh.call }
  end
end
