namespace :joss_vocabulary do
  desc "Build and activate a JOSS vocabulary model"
  task rebuild: :environment do
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    model = JossVocabularyAnalyzer.rebuild! { |message| puts message }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    puts "Created JOSS vocabulary model #{model.id} in #{elapsed.round(1)} seconds"
    puts "Source counts: #{model.source_counts.inspect}"
    puts "Top terms:"
    model.diagnostics.fetch("top_terms", []).each do |term|
      puts "  #{term.fetch('term')}: #{term.fetch('weight')}"
    end
  end

  desc "Show the active JOSS vocabulary model"
  task stats: :environment do
    model = JossVocabularyModel.latest
    abort "No JOSS vocabulary model exists" unless model

    puts "Model: #{model.id}"
    puts "Created: #{model.created_at.iso8601}"
    puts "Source counts: #{model.source_counts.inspect}"
    puts "Configuration: #{model.config.inspect}"
  end
end
