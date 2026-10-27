require "test_helper"

class ResearchEvidenceScoringTest < ActiveSupport::TestCase
  setup do
    JossVocabularyAnalyzer.stubs(:current_model).returns(nil)
    Sidekiq.redis { |redis| redis.call("DEL", RescoreProjectsWorker::STATE_KEY) }
  end

  teardown do
    Sidekiq.redis { |redis| redis.call("DEL", RescoreProjectsWorker::STATE_KEY) }
  end

  test "recurring refresh scores unresolved identifiers and badges without HTTP requests" do
    readmes = [
      "@inproceedings{hein2025, title={CheXalign}, url={https://aclanthology.org/2025.acl-long.1342/}}",
      ".. image:: https://zenodo.org/badge/618547854.svg\n   :target: https://zenodo.org/doi/10.5281/zenodo.10607452",
      "[![pyOpenSci Peer-Reviewed](https://pyopensci.org/badges/peer-reviewed.svg)](https://github.com/pyOpenSci/software-review/issues/42)",
      "[![rOpenSci review](https://badges.ropensci.org/126_status.svg)](https://github.com/ropensci/software-review/issues/126)"
    ]
    projects = readmes.each_with_index.map do |readme, index|
      Project.create!(url: "https://example.org/evidence-#{index}", readme: readme, science_score: 0)
    end

    result = RescoreProjectsWorker.new.perform

    assert_equal 0, result[:failed]
    assert_equal [20, 20, 20, 20], projects.map { |project| project.reload.science_score }
    assert_equal 0, ProjectPaper.where(project_id: projects.map(&:id)).count
    assert_equal [{ "kind" => "acl_id", "value" => "2025.acl-long.1342" }],
      projects.first.science_score_breakdown.dig("breakdown", "has_publication_identifier", "identifiers")
    assert_equal "rOpenSci", projects.last.science_score_breakdown.dig("breakdown", "has_peer_review_badge", "badges", 0, "program")
    assert_not_requested :any, /https?:\/\//
  end

  test "all supported identifier families score without resolution" do
    ["10.1234/example", "arXiv: 1810.04805v2", "PMID: 123456",
      "https://openreview.net/forum?id=ExampleID", "https://api.semanticscholar.org/CorpusID:12345"].each_with_index do |text, index|
      project = Project.create!(url: "https://example.org/identifier-#{index}", readme: text)
      project.update_science_score
      assert_equal 20, project.reload.science_score, text
    end
  end

  test "identifiers badges and resolved papers share one allowance without changing on resolution" do
    project = Project.create!(url: "https://example.org/combined", readme: <<~README)
      https://doi.org/10.1234/example
      https://arxiv.org/abs/1810.04805
      ![](https://pyopensci.org/badges/peer-reviewed.svg)
      ![](https://badges.ropensci.org/126_stats.svg)
      @article{example, title={Example}, doi={10.1234/example}}
    README
    project.update_science_score
    assert_equal 20, project.reload.science_score
    assert_equal "has_publication_identifier", project.science_score_breakdown.dig("breakdown", "has_peer_review_badge", "duplicate_of")
    paper = Paper.create!(doi: "10.1234/example", title: "Example")
    project.project_papers.create!(paper: paper, role: "reference", evidence: [{ "source" => "citation", "url" => project.url }])
    project.update_science_score
    assert_equal 20, project.reload.science_score
    assert_equal "has_resolved_paper", project.science_score_breakdown.dig("breakdown", "has_publication_identifier", "duplicate_of")
  end

  test "badge formats retain programme identity without checking review state" do
    inputs = {
      '<img src="https://WWW.PYOPENSCI.ORG/badges/peer-reviewed.svg">' => "pyOpenSci",
      '[![pyOpenSci](https://tinyurl.com/y22nb8up)](https://github.com/pyOpenSci/software-review/issues/37)' => "pyOpenSci",
      '<a href="https://github.com/pyOpenSci/software-review/issues/37"><img src="https://example.org/badge.svg"></a>' => "pyOpenSci",
      ".. image:: https://example.org/badge.svg\n   :target: https://github.com/ropensci/onboarding/issues/126" => "rOpenSci",
      '![](https://img.shields.io/badge/PyOpenSci-Peer%20Reviewed-success.svg)' => "pyOpenSci",
      ".. image:: https://badges.ropensci.org/222_stats.svg?style=flat" => "rOpenSci",
      "![status](https://joss.theoj.org/papers/0c10ef9eb9241f8b1ab7d0748c335b5b/status.svg)" => "JOSS",
      "![DOI](https://joss.theoj.org/papers/doi/10.21105/joss.01453/status.svg)" => "JOSS"
    }
    inputs.each_with_index do |(readme, program), index|
      project = Project.create!(url: "https://example.org/badge-#{index}", readme: readme)
      project.update_science_score
      assert_equal 20, project.reload.science_score
      assert_equal program, project.science_score_breakdown.dig("breakdown", "has_peer_review_badge", "badges", 0, "program")
    end
  end

  test "generic links titles and unrelated badges do not establish identifier or review evidence" do
    project = Project.create!(url: "https://example.org/unrelated", readme: <<~README)
      https://example.org/paper.pdf
      https://pyopensci.org/
      https://github.com/pyOpenSci/software-review/issues/37
      https://badges.ropensci.org.evil.example/126_status.svg
      https://example.org/?badge=https%3A%2F%2Fpyopensci.org%2Fbadges%2Fpeer-reviewed.svg
      ![](https://doi.org/10.1234/example.svg)
      ![](https://img.shields.io/badge/build-passing-green)
      @article{example, title={An unresolved title}}
    README
    project.update_science_score
    breakdown = project.reload.science_score_breakdown.fetch("breakdown")
    refute breakdown.dig("has_publication_identifier", "present")
    refute breakdown.dig("has_peer_review_badge", "present")
    assert_equal 8, project.science_score
  end

  test "CFF software DOI scores without a paper and retains independent citation credit" do
    project = Project.create!(url: "https://example.org/cff", citation_file: <<~CFF)
      cff-version: 1.2.0
      message: Cite this software
      title: Example
      doi: 10.5281/zenodo.10607452
      authors:
        - family-names: Example
    CFF
    project.update_science_score
    assert_equal 36, project.reload.science_score
  end
end
