namespace :research_organizations do
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
