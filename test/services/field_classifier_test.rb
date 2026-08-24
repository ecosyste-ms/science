require "test_helper"

class FieldClassifierTest < ActiveSupport::TestCase
  setup do
    @field = Field.create!(
      name: "biology",
      domain: "life_sciences",
      keywords: %w[genomics sequencing dna rna],
      packages: %w[biopython pysam],
      indicators: %w[genome sequencing alignment]
    )
    @classifier = FieldClassifier.new
  end

  def score_for(project)
    score, _signals = @classifier.send(:calculate_field_score, project, @field)
    score
  end

  test "score is monotonic in each signal" do
    strong_keywords = Project.new(url: "https://x", keywords: %w[genomics sequencing dna rna])

    no_readme = strong_keywords.dup
    zero_readme = strong_keywords.dup.tap { |p| p.readme = "unrelated content about web development" }
    weak_readme = strong_keywords.dup.tap { |p| p.readme = "genomics tool for web development" }

    assert_operator score_for(weak_readme), :>=, score_for(zero_readme),
                    "a small readme match must not score lower than a zero readme match"
    assert_operator score_for(no_readme), :>=, score_for(zero_readme),
                    "having a readme with no matches should not score higher than having no readme"
  end

  test "keyword match scores by overlap with field keywords" do
    full = Project.new(url: "https://x", keywords: %w[genomics sequencing dna rna])
    half = Project.new(url: "https://x", keywords: %w[genomics sequencing])
    assert_operator score_for(full), :>, score_for(half)
  end

  test "package match is a strong signal when any field package is a dependency" do
    p = Project.new(url: "https://x", packages: [{ "name" => "biopython" }])
    assert_operator score_for(p), :>=, 0.8
  end

  test "classify_project returns nothing when no field reaches primary threshold" do
    p = Project.new(url: "https://x", keywords: %w[unrelated])
    assert_equal [], @classifier.classify_project(p)
  end

  test "classify_project returns primary field above threshold" do
    p = Project.new(url: "https://x", keywords: %w[genomics sequencing dna rna])
    result = @classifier.classify_project(p)
    assert_equal @field, result.first[0]
    assert_operator result.first[1], :>=, FieldClassifier::PRIMARY_THRESHOLD
  end
end
