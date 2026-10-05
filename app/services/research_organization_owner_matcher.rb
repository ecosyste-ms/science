class ResearchOrganizationOwnerMatcher
  def self.call(owner)
    return "not_started" unless ResearchOrganizationImport.exists?(current: true)

    owner.with_lock do
      links = owner.owner_research_organizations
      automatic = links.where(source: "ror")
      if links.exists?(source: "manual")
        automatic.where.not(match_status: "superseded").update_all(match_status: "superseded", updated_at: Time.current)
        return "manual"
      end
      candidates = []
      input_domain = owner.website_domain.presence || owner.institutional_domain
      matched_domain = nil
      if owner.kind == "organization" && !owner.hidden? && input_domain.present?
        labels = input_domain.downcase.split(".")
        labels.each_index do |index|
          domain = labels[index..].join(".")
          candidates = ResearchOrganization.active.where("matching_domains @> ARRAY[?]::text[]", domain).to_a
          if candidates.any?
            matched_domain = domain
            break
          end
        end
      end
      status = candidates.size == 1 ? "matched" : "ambiguous"
      automatic.where.not(research_organization_id: candidates.map(&:id))
        .where.not(match_status: "superseded").update_all(match_status: "superseded", updated_at: Time.current)
      candidates.each do |organization|
        link = links.find_or_initialize_by(research_organization: organization, source: "ror", relationship: "repository_owner")
        domains = organization.metadata.fetch("domains").map { |domain| ResearchOrganizationDomainMatcher.normalize_domain(domain) }
        link.assign_attributes(match_status: status, match_method: domains.include?(matched_domain) ? "ror_domain" : "ror_website",
          evidence: { "input_domain" => input_domain, "matched_domain" => matched_domain,
            "ror_id" => organization.ror_id, "source_version" => organization.current_import.source_version,
            "retrieved_at" => organization.current_import.retrieved_at.iso8601 })
        if link.changed?
          link.observed_at = Time.current
          link.save!
        end
      end
      candidates.empty? ? "unmatched" : status
    end
  end
end
