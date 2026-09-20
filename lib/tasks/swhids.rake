namespace :swhids do
  desc "Count distinct SWHIDs archived after this app requested archival"
  task contributions: :environment do
    counts = SwhidArchiver.contribution_counts
    puts "SWHIDs archived after our request: #{counts.fetch('total')}"
    puts "Revisions: #{counts.fetch('revisions')}"
    puts "Directories: #{counts.fetch('directories')}"
  end
end
