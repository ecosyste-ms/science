namespace :authors do
  desc "refresh cached public evidence counts (LIMIT=1000 AFTER_ID=0)"
  task sync_public_evidence_counts: :environment do
    result = AuthorPublicEvidenceCounter.sync_batch!(
      limit: ENV.fetch("LIMIT", AuthorPublicEvidenceCounter::DEFAULT_LIMIT),
      after_id: ENV.fetch("AFTER_ID", "0")
    )
    puts "Author public evidence counts: #{result.inspect}"
  end
end
