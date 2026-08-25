require "yaml"

class ManualResearchOrganizationDomainImporter
  DATA_PATH = Rails.root.join("db/seeds/research_organization_domains.yml")

  class << self
    def sync!(path: DATA_PATH)
      data = YAML.safe_load_file(path)
      version = data.fetch("version").to_s
      if ResearchOrganizationDomain.active_version_for("manual") == version
        ResearchOrganizationDomain.prune_inactive!("manual")
        return {
          source: "manual",
          version: version,
          domains: ResearchOrganizationDomain.active.where(source: "manual").count,
          imported: false,
        }
      end

      ResearchOrganizationDomain.where(source: "manual", source_version: version, active: false).delete_all
      now = Time.current
      rows = data.fetch("domains").map do |domain|
        normalized = ResearchOrganizationDomainMatcher.normalize_domain(domain)
        raise "Invalid manual research organization domain: #{domain.inspect}" unless normalized

        {
          domain: normalized,
          source: "manual",
          source_version: version,
          active: false,
          external_id: normalized,
          organization_types: [],
          strength: 1.0,
          created_at: now,
          updated_at: now,
        }
      end
      ResearchOrganizationDomain.insert_all!(rows)
      ResearchOrganizationDomain.activate_version!(source: "manual", version: version)
      { source: "manual", version: version, domains: rows.length, imported: true }
    rescue StandardError
      ResearchOrganizationDomain.where(source: "manual", source_version: version, active: false).delete_all if version
      raise
    end
  end
end
