require "test_helper"

class ResearchOrganizationDomainTest < ActiveSupport::TestCase
  test "active version switches atomically within a source" do
    old_domain = create_research_organization_domain("old.example", source: "ror", version: "old")
    new_domain = create_research_organization_domain("new.example", source: "ror", version: "new", active: false)

    ResearchOrganizationDomain.activate_version!(source: "ror", version: "new")

    assert_not ResearchOrganizationDomain.exists?(old_domain.id)
    assert new_domain.reload.active?
  end

  test "domain requires a valid strength" do
    domain = ResearchOrganizationDomain.new(
      domain: "example.org",
      source: "ror",
      source_version: "one",
      external_id: "https://ror.org/example",
      strength: 1.2
    )

    assert_not domain.valid?
  end
end
