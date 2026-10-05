namespace :research_organizations do
  desc "Import full ROR JSON records (optional: JSON_FILE=path VERSION=release MINIMUM_RECORDS=10000 BATCHES=1)"
  task import_ror: :environment do
    options = { minimum_records: Integer(ENV.fetch("MINIMUM_RECORDS", "10000"), 10),
      max_batches: ENV["BATCHES"].present? ? Integer(ENV.fetch("BATCHES"), 10) : nil,
      progress: ->(message) { puts message } }
    result = if ENV["JSON_FILE"].present?
      RorResearchOrganizationImporter.import_file!(ENV.fetch("JSON_FILE"), source_version: ENV.fetch("VERSION"), **options)
    else
      RorResearchOrganizationImporter.sync!(**options)
    end
    puts JSON.generate(result)
  end

  desc "Backfill ROR owner associations (optional: LIMIT=100 BATCHES=1 RESTART=true)"
  task backfill: :environment do
    result = ResearchOrganizationOwnerBackfill.call(limit: Integer(ENV.fetch("LIMIT", "100"), 10),
      max_batches: ENV["BATCHES"].present? ? Integer(ENV.fetch("BATCHES"), 10) : nil,
      restart: ENV["RESTART"] == "true", progress: ->(message) { puts message })
    puts JSON.generate(result)
  end

  desc "Inspect saved ROR owner associations (OWNER_ID=id)"
  task owner_links: :environment do
    owner = Owner.visible.find(ENV.fetch("OWNER_ID"))
    puts JSON.generate(owner.owner_research_organizations.includes(:research_organization).order(:id).map do |link|
      { ror_id: link.research_organization.ror_id, name: link.research_organization.display_name,
        country_codes: link.research_organization.country_codes, source: link.source,
        relationship: link.relationship, match_status: link.match_status, evidence: link.evidence }
    end)
  end

  desc "Import current research organization domains and reclassify owners"
  task sync: :environment do
    result = ResearchOrganizationDomainRefresh.call(progress: ->(message) { puts message })
    puts "Manual version: #{result.dig(:manual, :version)}"
    puts "ROR version: #{result.dig(:ror, :version)}"
    puts "Owner classification: #{result[:owners]&.inspect || 'unchanged'}"
  end

  desc "Reclassify owners using the active research organization domains"
  task reclassify_owners: :environment do
    counts = Owner.reclassify_research_organizations!(progress: ->(message) { puts message })
    puts "Owner classification: #{counts.inspect}"
  end

  desc "Show active research organization domain sources"
  task stats: :environment do
    ResearchOrganizationDomain.active.group(:source, :source_version, :published_at).count.each do |(source, version, published_at), count|
      puts "#{source}: version=#{version} domains=#{count} published=#{published_at&.iso8601}"
    end
    puts "Institutional owners: #{Owner.institutional.count}"
  end
end
