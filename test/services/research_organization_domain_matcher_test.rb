require "test_helper"

class ResearchOrganizationDomainMatcherTest < ActiveSupport::TestCase
  def setup
    create_research_organization_domain(
      "inbo.be",
      source: "ror",
      version: "matcher",
      external_id: "https://ror.org/00j54wy13",
      organization_name: "Research Institute for Nature and Forest",
      organization_types: ["facility"],
      strength: 1.0
    )
    create_research_organization_domain(
      "example.com",
      source: "ror",
      version: "matcher",
      external_id: "https://ror.org/company",
      organization_name: "Example Research Company",
      organization_types: ["company"],
      strength: 0.4
    )
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  def teardown
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "matches exact and subdomains from the active table" do
    exact = ResearchOrganizationDomainMatcher.match("inbo.be")
    subdomain = ResearchOrganizationDomainMatcher.match("data.inbo.be")

    assert_equal "https://ror.org/00j54wy13", exact[:external_id]
    assert_equal "inbo.be", subdomain[:domain]
    assert_equal 1.0, subdomain[:strength]
  end

  test "retains weaker company evidence" do
    match = ResearchOrganizationDomainMatcher.match("labs.example.com")

    assert_equal 0.4, match[:strength]
    assert_equal ["company"], match[:organization_types]
  end

  test "rejects substring matches" do
    assert_nil ResearchOrganizationDomainMatcher.match("notinbo.be")
  end

  test "extracts a normalized domain from an owner website" do
    assert_equal "data.inbo.be", ResearchOrganizationDomainMatcher.domain_from_url("https://www.data.inbo.be/projects")
  end
end
