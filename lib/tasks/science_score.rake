require 'science_score_analysis'

namespace :science_score do
  desc 'Compare local ScienceScoreCalculator against a stratified sample from the prod API'
  task compare: :environment do
    ScienceScoreAnalysis.compare
  end

  desc 'Compare attribute prevalence in JOSS vs non-JOSS projects (SAMPLE=200)'
  task joss_signals: :environment do
    ScienceScoreAnalysis.joss_signals(sample: (ENV['SAMPLE'] || 200).to_i)
  end
end
