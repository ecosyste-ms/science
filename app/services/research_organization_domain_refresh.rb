class ResearchOrganizationDomainRefresh
  class << self
    def call(progress: nil)
      manual = ManualResearchOrganizationDomainImporter.sync!
      progress&.call("Manual domains: #{manual.fetch(:domains)}")

      ror = nil
      owner_counts = nil
      begin
        ror = RorResearchOrganizationDomainImporter.sync!
        progress&.call("ROR domains: #{ror.fetch(:domains)}")
      ensure
        changed = manual.fetch(:imported) || ror&.fetch(:imported)
        owner_counts = Owner.reclassify_research_organizations!(progress: progress) if changed
      end
      { manual: manual, ror: ror, owners: owner_counts }
    end
  end
end
