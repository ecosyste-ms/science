namespace :open_alex do
  desc "Sync the OpenAlex taxonomy and DOI topic labels"
  task sync: :environment do
    client = OpenAlexApiClient.new
    progress = ->(message) { puts message }

    taxonomy = OpenAlexTaxonomyImporter.sync!(
      client: client,
      progress: progress
    )
    puts "OpenAlex taxonomy: #{taxonomy.inspect}"

    joss = OpenAlexProjectTopicImporter.sync!(
      source: OpenAlexProjectTopicImporter::JOSS_SOURCE,
      client: client,
      progress: progress
    )
    puts "OpenAlex JOSS topics: #{joss.inspect}"

    readme = OpenAlexProjectTopicImporter.sync!(
      source: OpenAlexProjectTopicImporter::README_DOI_SOURCE,
      client: client,
      progress: progress
    )
    puts "OpenAlex README DOI topics: #{readme.inspect}"

    arxiv = OpenAlexProjectTopicImporter.sync!(
      source: OpenAlexProjectTopicImporter::README_ARXIV_SOURCE,
      client: client,
      progress: progress
    )
    puts "OpenAlex README arXiv topics: #{arxiv.inspect}"

    metadata = OpenAlexProjectTopicImporter.sync!(
      source: OpenAlexProjectTopicImporter::METADATA_DOI_SOURCE,
      client: client,
      progress: progress
    )
    puts "OpenAlex metadata DOI topics: #{metadata.inspect}"
  end

  desc "Compare repository-text predictions with all topics for each OpenAlex work (optional: LIMIT=n)"
  task validation: :environment do
    report = OpenAlexValidationReport.new(limit: ENV["LIMIT"])
    result = report.generate
    report.summary_lines(result).each { |line| warn line }
  end

  desc "Rebuild ranked OpenAlex fields for scientific projects (optional: LIMIT=n)"
  task classify_fields: :environment do
    result = OpenAlexFieldClassificationImporter.sync!(
      limit: ENV["LIMIT"],
      progress: ->(message) { puts message }
    )
    puts "OpenAlex field classifications: #{result.inspect}"
  end
end
