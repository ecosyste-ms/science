namespace :open_alex do
  desc "Sync the OpenAlex taxonomy and JOSS project topics"
  task sync: :environment do
    client = OpenAlexApiClient.new
    progress = ->(message) { puts message }

    taxonomy = OpenAlexTaxonomyImporter.sync!(
      client: client,
      progress: progress
    )
    puts "OpenAlex taxonomy: #{taxonomy.inspect}"

    joss = OpenAlexJossTopicImporter.sync!(
      client: client,
      progress: progress
    )
    puts "OpenAlex JOSS topics: #{joss.inspect}"
  end
end
