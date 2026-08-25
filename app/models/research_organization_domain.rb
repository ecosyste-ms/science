class ResearchOrganizationDomain < ApplicationRecord
  validates :domain, presence: true
  validates :source, presence: true
  validates :source_version, presence: true
  validates :external_id, presence: true
  validates :strength, inclusion: { in: 0.0..1.0 }

  scope :active, -> { where(active: true) }

  class << self
    def active_version_for(source)
      active.where(source: source).pick(:source_version)
    end

    def prune_inactive!(source)
      where(source: source, active: false).delete_all
    end

    def activate_version!(source:, version:)
      transaction do
        replacement = where(source: source, source_version: version)
        raise "No research organization domains for #{source} version #{version}" unless replacement.exists?

        where(source: source, active: true).update_all(active: false)
        replacement.update_all(active: true)
      end

      prune_inactive!(source)
      ResearchOrganizationDomainMatcher.reset_cache!
    end
  end
end
