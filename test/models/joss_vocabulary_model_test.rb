require "test_helper"

class JossVocabularyModelTest < ActiveSupport::TestCase
  test "latest returns the newest model" do
    older = JossVocabularyModel.create!(
      term_weights: { "plasma" => 1.0 },
      config: { "top_terms" => 3 },
      source_counts: { "joss_projects" => 1 },
      created_at: 1.day.ago
    )
    newer = JossVocabularyModel.create!(
      term_weights: { "simulation" => 1.0 },
      config: { "top_terms" => 3 },
      source_counts: { "joss_projects" => 1 }
    )

    assert_equal newer, JossVocabularyModel.latest
    refute_equal older, JossVocabularyModel.latest
  end
end
