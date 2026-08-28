require "test_helper"

class ProjectClassificationTest < ActiveSupport::TestCase
  setup do
    Project.instance_variable_set(:@all_category_keywords, nil)
    Project.instance_variable_set(:@all_sub_category_keywords, nil)
  end

  test "unique_keywords_for_category returns keywords appearing only in that category" do
    Project.create!(url: "https://github.com/a/1", category: "biology", keywords: %w[cells dna shared])
    Project.create!(url: "https://github.com/a/2", category: "biology", keywords: %w[cells])
    Project.create!(url: "https://github.com/b/1", category: "physics", keywords: %w[quantum shared])

    result = Project.unique_keywords_for_category("biology")
    assert_equal %w[cells dna], result
  end

  test "unique_keywords_for_sub_category returns keywords appearing only in that sub_category" do
    Project.create!(url: "https://github.com/a/1", sub_category: "genomics", keywords: %w[dna sequencing])
    Project.create!(url: "https://github.com/b/1", sub_category: "optics", keywords: %w[laser sequencing])

    assert_equal %w[dna], Project.unique_keywords_for_sub_category("genomics")
  end

  test "category_tree groups counts by category and sub_category" do
    Project.create!(url: "https://github.com/a/1", category: "biology", sub_category: "genomics")
    Project.create!(url: "https://github.com/a/2", category: "biology", sub_category: "ecology")
    Project.create!(url: "https://github.com/b/1", category: "physics", sub_category: "optics")

    tree = Project.category_tree
    bio = tree.find { |c| c[:category] == "biology" }
    assert_equal 2, bio[:count]
    assert_equal 2, bio[:sub_categories].length
    assert_equal 1, tree.find { |c| c[:category] == "physics" }[:count]
  end

  test "suggest_category picks category with most keyword overlap" do
    Project.create!(url: "https://github.com/a/1", category: "biology", keywords: %w[dna cells])
    Project.create!(url: "https://github.com/b/1", category: "physics", keywords: %w[quantum])

    p = Project.new(url: "https://github.com/x/y", keywords: %w[dna cells other])
    assert_equal "biology", p.suggest_category[:category]
  end

  test "suggest_category returns nil when no keyword overlap" do
    Project.create!(url: "https://github.com/a/1", category: "biology", keywords: %w[dna])
    p = Project.new(url: "https://github.com/x/y", keywords: %w[unrelated])
    assert_nil p.suggest_category
  end

  test "suggest_category returns nil when project has no keywords" do
    assert_nil Project.new(url: "https://github.com/x/y").suggest_category
  end

  test "all_fields_with_confidence sorts project_fields by confidence descending" do
    project = Project.create!(url: "https://github.com/x/y")
    f1 = Field.create!(name: "biology", domain: "life-sciences")
    f2 = Field.create!(name: "physics", domain: "physical-sciences")
    ProjectField.create!(project: project, field: f1, confidence_score: 0.3)
    ProjectField.create!(project: project, field: f2, confidence_score: 0.9)

    result = project.all_fields_with_confidence
    assert_equal [[f2, 0.9], [f1, 0.3]], result
  end

  test "contributor_topics counts stemmed topics across contributors above minimum" do
    p = Project.new(url: "https://github.com/x/y", commits: { "committers" => [{}, {}] }, keywords: [])
    c1 = stub(topics: %w[genomics genomic sequencing])
    c2 = stub(topics: %w[genomics proteomics])
    p.stubs(:contributors).returns([c1, c2])
    Project.stubs(:ignore_words).returns([])

    result = p.contributor_topics(limit: 10, minimum: 2)
    assert result.key?("genomics")
    assert_equal 3, result["genomics"]
    refute result.key?("proteomics")
  end

  test "contributor_topics returns empty hash when fewer than 2 contributors" do
    p = Project.new(url: "https://github.com/x/y", commits: { "committers" => [{}] })
    p.stubs(:contributors).returns([stub(topics: %w[a b])])
    assert_equal({}, p.contributor_topics)
  end

  test "update_keywords_from_contributors persists contributor_topics keys" do
    p = Project.create!(url: "https://github.com/x/y")
    p.stubs(:contributor_topics).returns({ "genomics" => 5, "sequencing" => 3 })
    p.update_keywords_from_contributors
    assert_equal %w[genomics sequencing], p.reload.keywords_from_contributors
  end

end
