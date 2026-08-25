require 'test_helper'

class ScienceScoreCalculatorTest < ActiveSupport::TestCase
  def setup
    JossVocabularyAnalyzer.reset_cache!
    @project = Project.create!(url: 'https://github.com/test/science-project')
  end

  test "calculate detects scientific vocabulary through the public boundary" do
    model = JossVocabularyModel.create!(
      term_weights: { "plasma" => 2.0, "simulation" => 1.5, "mpi4py" => 1.0 },
      config: { "top_terms" => 3, "evidence_threshold" => 4.0 },
      source_counts: { "joss_projects" => 100, "background_projects" => 1_000 }
    )
    @project.update!(
      description: "Plasma simulation solver",
      readme: "Sparse Fortran model using mpi4py"
    )

    result = ScienceScoreCalculator.new(@project).calculate
    vocabulary = result[:breakdown][:joss_vocabulary_similarity]

    assert vocabulary[:present]
    assert_equal model.id, vocabulary[:model_id]
    assert_equal %w[plasma simulation mpi4py], vocabulary[:terms]
    assert result[:score] > 0
  end

  test "calculate returns score and breakdown" do
    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.calculate
    
    assert_not_nil result[:score]
    assert_not_nil result[:breakdown]
    assert_equal 100, result[:max_score]
  end

  test "check_citation_file detects citation file" do
    @project.citation_file = 'test citation content'
    calculator = ScienceScoreCalculator.new(@project)
    
    result = calculator.check_citation_file
    
    assert result[:present]
    assert_equal "CITATION.cff file", result[:description]
    assert_equal "Found CITATION.cff file", result[:details]
  end

  test "check_doi_in_readme detects DOIs" do
    @project.readme = "This research is published at https://doi.org/10.1234/example"
    calculator = ScienceScoreCalculator.new(@project)
    
    result = calculator.check_doi_in_readme
    
    assert result[:present]
    assert_equal "DOI references", result[:description]
    assert_match(/Found \d+ DOI reference/, result[:details])
  end

  test "check_academic_links detects academic sites" do
    @project.readme = "Published on arxiv.org and available at researchgate.net"
    calculator = ScienceScoreCalculator.new(@project)
    
    result = calculator.check_academic_links
    
    assert result[:present]
    assert_equal "Academic publication links", result[:description]
    assert_match(/arxiv\.org/, result[:details])
    assert_match(/researchgate\.net/, result[:details])
  end

  test "check_academic_committers detects academic emails" do
    @project.commits = {
      'committers' => [
        {'name' => 'John Doe', 'email' => 'john@university.edu', 'count' => 10},
        {'name' => 'Jane Smith', 'email' => 'jane@college.ac.uk', 'count' => 5},
        {'name' => 'Bob Wilson', 'email' => 'bob@gmail.com', 'count' => 3}
      ]
    }
    
    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_academic_committers
    
    assert result[:present]
    assert_equal "Committers with academic emails", result[:description]
    assert_match(/2 of 3 committers/, result[:details])
    assert_equal 2, result[:committers].length
  end

  test "calculate_score returns percentage based on present indicators" do
    @project.citation_file = 'test citation content'
    @project.readme = "DOI: 10.1234/example"
    @project.joss_metadata = {'title' => 'Test Paper'}
    
    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.calculate
    
    assert result[:score] > 0
    assert result[:score] <= 100
    assert result[:breakdown][:has_citation_file][:present]
    assert result[:breakdown][:has_doi_in_readme][:present]
    assert result[:breakdown][:has_joss_paper][:present]
  end

  test "calculate_score returns 0 when no indicators present" do
    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.calculate

    assert_equal 0.0, result[:score]
    assert_not result[:breakdown][:has_citation_file][:present]
    assert_not result[:breakdown][:has_doi_in_readme][:present]
    assert_not result[:breakdown][:has_academic_links][:present]
  end

  test "check_institutional_owner detects organization with edu domain" do
    host = Host.create!(name: 'GitHub')
    owner = Owner.create!(host: host, login: 'stanford', kind: 'organization')
    @project.update(host: host, owner_record: owner)
    @project.update_column(:owner, { 'website' => 'stanford.edu' })

    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_institutional_owner

    assert result[:present]
    assert_equal "Institutional organization owner", result[:description]
    assert_match(/stanford/, result[:details])
    assert_match(/stanford.edu/, result[:details])
  end

  test "check_institutional_owner detects organization with gov domain" do
    host = Host.create!(name: 'GitHub')
    owner = Owner.create!(host: host, login: 'nasa', kind: 'organization')
    @project.update(host: host, owner_record: owner)
    @project.update_column(:owner, { 'website' => 'https://nasa.gov' })

    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_institutional_owner

    assert result[:present]
    assert_match(/nasa/, result[:details])
  end

  test "check_institutional_owner returns false for non-institutional domain" do
    host = Host.create!(name: 'GitHub')
    owner = Owner.create!(host: host, login: 'mycompany', kind: 'organization')
    @project.update(host: host, owner_record: owner)
    @project.update_column(:owner, { 'website' => 'mycompany.com' })

    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_institutional_owner

    assert_not result[:present]
  end

  test "check_institutional_owner returns false for user owner" do
    host = Host.create!(name: 'GitHub')
    owner = Owner.create!(host: host, login: 'johndoe', kind: 'user')
    @project.update(host: host, owner_record: owner)
    @project.update_column(:owner, { 'website' => 'johndoe.edu' })

    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_institutional_owner

    assert_not result[:present]
  end

  test "check_institutional_owner returns false when no owner" do
    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_institutional_owner

    assert_not result[:present]
  end

  test "academic_domain? matches suffixes on label boundaries" do
    assert ScienceScoreCalculator.academic_domain?("stanford.edu")
    assert ScienceScoreCalculator.academic_domain?("cs.stanford.edu")
    assert ScienceScoreCalculator.academic_domain?("cam.ac.uk")
    assert ScienceScoreCalculator.academic_domain?("something.mpg.de")
    assert ScienceScoreCalculator.academic_domain?("nasa.gov")
  end

  test "academic_domain? matches label prefixes" do
    assert ScienceScoreCalculator.academic_domain?("uni-hamburg.de")
    assert ScienceScoreCalculator.academic_domain?("tu-berlin.de")
    assert ScienceScoreCalculator.academic_domain?("univ-lyon1.fr")
    assert ScienceScoreCalculator.academic_domain?("u-bordeaux.fr")
  end

  test "academic_domain? matches label words" do
    assert ScienceScoreCalculator.academic_domain?("university.example")
    assert ScienceScoreCalculator.academic_domain?("mail.college.example")
  end

  test "academic_domain? rejects substring false positives" do
    refute ScienceScoreCalculator.academic_domain?("reduce.io")
    refute ScienceScoreCalculator.academic_domain?("universal-robots.com")
    refute ScienceScoreCalculator.academic_domain?("education.com")
    refute ScienceScoreCalculator.academic_domain?("myuniversity.com")
    refute ScienceScoreCalculator.academic_domain?("statu-quo.com")
    refute ScienceScoreCalculator.academic_domain?("acme.com")
    refute ScienceScoreCalculator.academic_domain?(nil)
  end

  test "check_academic_committers reports fraction as strength" do
    @project.commits = {
      'committers' => [
        { 'name' => 'a', 'email' => 'a@stanford.edu', 'count' => 10 },
        { 'name' => 'b', 'email' => 'b@gmail.com', 'count' => 5 },
        { 'name' => 'c', 'email' => 'c@gmail.com', 'count' => 5 },
        { 'name' => 'd', 'email' => 'd@gmail.com', 'count' => 5 },
      ],
    }
    result = ScienceScoreCalculator.new(@project).check_academic_committers
    assert result[:present]
    assert_in_delta 0.25, result[:strength]
  end

  test "check_scientific_registry detects cran/bioconductor" do
    @project.packages = [{ 'ecosystem' => 'cran', 'name' => 'ggplot2' }]
    result = ScienceScoreCalculator.new(@project).check_scientific_registry
    assert result[:present]
    assert_equal "Published on cran", result[:details]

    @project.packages = [{ 'ecosystem' => 'npm', 'name' => 'react' }]
    refute ScienceScoreCalculator.new(@project).check_scientific_registry[:present]

    @project.packages = nil
    refute ScienceScoreCalculator.new(@project).check_scientific_registry[:present]
  end

  test "check_doi_in_readme classifies archive vs journal dois" do
    @project.readme = "Archived at https://doi.org/10.5281/zenodo.12345 and published at https://doi.org/10.1038/s41586-020-1234"
    result = ScienceScoreCalculator.new(@project).check_doi_in_readme
    assert result[:present]
    assert_equal 1, result[:archive_dois]
    assert_equal 1, result[:journal_dois]
    assert_match "1 journal, 1 archive", result[:details]
  end

  test "calculate_score applies strength multiplier for fractional signals" do
    @project.commits = {
      'committers' => [
        { 'name' => 'a', 'email' => 'a@stanford.edu', 'count' => 1 },
        { 'name' => 'b', 'email' => 'b@stanford.edu', 'count' => 1 },
      ],
    }
    full = ScienceScoreCalculator.new(@project).calculate[:score]

    @project.commits = {
      'committers' => [
        { 'name' => 'a', 'email' => 'a@stanford.edu', 'count' => 1 },
        { 'name' => 'b', 'email' => 'b@gmail.com', 'count' => 1 },
      ],
    }
    half = ScienceScoreCalculator.new(@project).calculate[:score]

    assert full > half
    assert half > 0
  end

  test "check_scientific_dependencies fires when project's own package is in the list" do
    @project.packages = [{ 'ecosystem' => 'pypi', 'name' => 'astropy' }]
    @project.stubs(:dependency_packages).returns([])
    result = ScienceScoreCalculator.new(@project).check_scientific_dependencies
    assert result[:present]
    assert_equal 1.0, result[:strength]
    assert_match "Package is in the scientific dependency list", result[:details]
  end

  test "check_scientific_dependencies scores by match count" do
    @project.stubs(:dependency_packages).returns([['pypi', 'astropy'], ['pypi', 'requests']])
    result = ScienceScoreCalculator.new(@project).check_scientific_dependencies
    assert result[:present]
    assert_equal 0.4, result[:strength]
    assert_equal 1, result[:matches]
    assert_match 'pypi:astropy', result[:details]

    @project.stubs(:dependency_packages).returns([['pypi', 'astropy'], ['pypi', 'scipy'], ['cran', 'sf']])
    result = ScienceScoreCalculator.new(@project).check_scientific_dependencies
    assert_equal 1.0, result[:strength]
    assert_equal 3, result[:matches]
  end

  test "check_scientific_dependencies absent with no matches" do
    @project.stubs(:dependency_packages).returns([['npm', 'react'], ['pypi', 'requests']])
    refute ScienceScoreCalculator.new(@project).check_scientific_dependencies[:present]

    @project.stubs(:dependency_packages).returns([])
    refute ScienceScoreCalculator.new(@project).check_scientific_dependencies[:present]
  end

  test "check_scientific_dependencies matches case-insensitively across ecosystems" do
    @project.stubs(:dependency_packages).returns([['PyPI', 'ASTROPY'], ['bioconductor', 'DESeq2']])
    result = ScienceScoreCalculator.new(@project).check_scientific_dependencies
    assert_equal 2, result[:matches]
    assert_equal 0.7, result[:strength]
  end

  test "check_scientific_dependencies deduplicates packages across ecosystems" do
    @project.stubs(:dependency_packages).returns([
      ['conda', 'scipy'],
      ['pypi', 'SCIPY'],
      ['pypi', 'requests'],
    ])

    result = ScienceScoreCalculator.new(@project).check_scientific_dependencies

    assert_equal 1, result[:matches]
    assert_equal 0.4, result[:strength]
    assert_equal "1 matched: conda:scipy", result[:details]
  end

  test "calculate adds points only for strong scientific dependency evidence" do
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)
    @project.stubs(:dependency_packages).returns([
      ['pypi', 'astropy'],
      ['pypi', 'scipy'],
      ['cran', 'sf'],
    ])

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 8.0, result[:score]
    assert_equal 8.0, result[:breakdown][:has_scientific_dependencies][:score]

    @project.stubs(:dependency_packages).returns([
      ['pypi', 'astropy'],
      ['pypi', 'scipy'],
    ])

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 0.0, result[:score]
    assert_equal 0.0, result[:breakdown][:has_scientific_dependencies][:score]
  end

  test "calculate applies negative indicators after the scientific dependency bonus" do
    @project.repository = { 'topics' => ['awesome-list'] }
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)
    @project.stubs(:dependency_packages).returns([
      ['pypi', 'astropy'],
      ['pypi', 'scipy'],
      ['cran', 'sf'],
    ])

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 1.6, result[:score]
    assert_equal 8.0, result[:breakdown][:has_scientific_dependencies][:score]
  end

  test "check_research_tooling detects tools by taxonomy domain" do
    @project.brief = { "tools" => { "build" => [{ "name" => "Snakemake", "taxonomy" => { "domain" => ["research"] } }] } }
    result = ScienceScoreCalculator.new(@project).check_research_tooling
    assert result[:present]
    assert_equal 1.0, result[:strength]
    assert_match "domain: research", result[:details]
  end

  test "check_research_tooling falls back to name matching by tier" do
    @project.brief = { "tools" => { "docs" => [{ "name" => "Quarto" }] } }
    result = ScienceScoreCalculator.new(@project).check_research_tooling
    assert result[:present]
    assert_equal 0.4, result[:strength]

    @project.brief = { "tools" => { "environment" => [{ "name" => "Jupyter" }] } }
    result = ScienceScoreCalculator.new(@project).check_research_tooling
    assert_equal 0.4, result[:strength]

    @project.brief = { "tools" => { "test" => [{ "name" => "pytest" }] } }
    refute ScienceScoreCalculator.new(@project).check_research_tooling[:present]
  end

  test "calculate gives a strong Fortran project the research tooling bonus" do
    @project.brief = { "languages" => [{ "name" => "Fortran" }], "tools" => {} }
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 20.0, result[:score]
    assert result[:breakdown][:has_research_tooling][:present]
    assert_equal 1.0, result[:breakdown][:has_research_tooling][:strength]
    assert_match "language: fortran", result[:breakdown][:has_research_tooling][:details]
  end

  test "calculate does not add Python maturity points without scientific vocabulary" do
    @project.citation_file = "citation"
    @project.brief = {
      "languages" => [{ "name" => "Python" }],
      "tools" => {
        "docs" => [{ "name" => "Sphinx" }],
        "test" => [{ "name" => "pytest" }],
        "coverage" => [{ "name" => "coverage.py" }],
        "lint" => [{ "name" => "Ruff" }],
        "typecheck" => [{ "name" => "Pyright" }],
      },
    }
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 16.0, result[:score]
    assert_equal 0.4, result[:breakdown][:has_research_tooling][:strength]
    assert_equal 0.0, result[:breakdown][:has_research_tooling][:score]
    assert_match "Python maturity", result[:breakdown][:has_research_tooling][:details]
  end

  test "calculate combines scientific vocabulary with mature Python tooling" do
    JossVocabularyModel.create!(
      term_weights: { "plasma" => 2.0, "simulation" => 1.5 },
      config: { "top_terms" => 3, "evidence_threshold" => 3.0 },
      source_counts: { "joss_projects" => 100, "background_projects" => 1_000 }
    )
    JossVocabularyAnalyzer.reset_cache!
    @project.readme = "Plasma simulation software"
    @project.brief = {
      "languages" => [{ "name" => "Python" }],
      "tools" => {
        "docs" => [{ "name" => "Sphinx" }],
        "test" => [{ "name" => "pytest" }],
        "coverage" => [{ "name" => "coverage.py" }],
      },
    }

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 21.0, result[:score]
    assert result[:breakdown][:joss_vocabulary_similarity][:present]
    assert_equal 0.4, result[:breakdown][:has_research_tooling][:strength]
    assert_equal 8.0, result[:breakdown][:has_research_tooling][:score]
  end

  test "check_research_tooling detects language-specific R and Julia combinations" do
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)
    @project.brief = {
      "languages" => [{ "name" => "R" }],
      "package_managers" => [],
      "tools" => {
        "docs" => [{ "name" => "pkgdown" }, { "name" => "roxygen2" }],
      },
    }
    r_result = ScienceScoreCalculator.new(@project).check_research_tooling

    assert_equal 0.7, r_result[:strength]
    assert_match "R tooling", r_result[:details]
    assert_equal 14.0, ScienceScoreCalculator.new(@project).calculate[:score]

    @project.brief = {
      "languages" => [{ "name" => "Julia" }],
      "package_managers" => [{ "name" => "Pkg" }],
      "tools" => { "docs" => [{ "name" => "Documenter.jl" }] },
    }
    julia_result = ScienceScoreCalculator.new(@project).check_research_tooling

    assert_equal 0.7, julia_result[:strength]
    assert_match "Julia tooling", julia_result[:details]
    assert_equal 14.0, ScienceScoreCalculator.new(@project).calculate[:score]
  end

  test "calculate requires vocabulary for standalone R authoring tools" do
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)
    @project.brief = {
      "languages" => [{ "name" => "R" }],
      "tools" => { "docs" => [{ "name" => "R Markdown" }, { "name" => "knitr" }] },
    }

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 0.0, result[:score]
    assert_equal 0.4, result[:breakdown][:has_research_tooling][:strength]
    assert_equal 0.0, result[:breakdown][:has_research_tooling][:score]
  end

  test "calculate requires vocabulary for one R package tool" do
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)
    @project.brief = {
      "languages" => [{ "name" => "R" }],
      "tools" => { "workflow" => [{ "name" => "targets" }] },
    }

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 0.0, result[:score]
    assert_equal 0.4, result[:breakdown][:has_research_tooling][:strength]
    assert_equal 0.0, result[:breakdown][:has_research_tooling][:score]
  end

  test "calculate requires vocabulary for Julia Pkg alone" do
    @project.stubs(:joss_vocabulary_analysis).returns(score: 0, terms: [], model_id: nil)
    @project.brief = {
      "languages" => [{ "name" => "Julia" }],
      "package_managers" => [{ "name" => "Pkg" }],
      "tools" => {},
    }

    result = ScienceScoreCalculator.new(@project).calculate

    assert_equal 0.0, result[:score]
    assert_equal 0.4, result[:breakdown][:has_research_tooling][:strength]
    assert_equal 0.0, result[:breakdown][:has_research_tooling][:score]
  end

  test "check_research_tooling does not treat a generic C++ build as research" do
    @project.brief = {
      "languages" => [{ "name" => "C++" }],
      "tools" => {
        "build" => [{ "name" => "CMake" }],
        "format" => [{ "name" => "clang-format" }],
      },
    }

    result = ScienceScoreCalculator.new(@project).check_research_tooling

    refute result[:present]
  end

  test "check_research_tooling absent when no brief data" do
    refute ScienceScoreCalculator.new(@project).check_research_tooling[:present]
  end

  test "check_research_tooling absent when brief scan errored" do
    @project.brief = { "error" => "clone failed", "attempted_at" => Time.now.iso8601 }
    result = ScienceScoreCalculator.new(@project).check_research_tooling
    refute result[:present]
    assert_match "scan error", result[:details]
  end

  test "check_negative_indicators detects strong topics" do
    @project.repository = { 'topics' => ['awesome-list', 'python'] }
    result = ScienceScoreCalculator.new(@project).check_negative_indicators
    assert result[:present]
    assert_equal 0.8, result[:penalty]
    assert_match 'topic:awesome-list', result[:details]
  end

  test "check_negative_indicators detects weak topics" do
    @project.repository = { 'topics' => ['tutorial'] }
    result = ScienceScoreCalculator.new(@project).check_negative_indicators
    assert result[:present]
    assert_equal 0.5, result[:penalty]
  end

  test "check_negative_indicators detects awesome- name pattern" do
    @project.repository = { 'full_name' => 'user/awesome-bioinformatics', 'topics' => [] }
    result = ScienceScoreCalculator.new(@project).check_negative_indicators
    assert result[:present]
    assert_equal 0.8, result[:penalty]
  end

  test "check_negative_indicators absent for normal project" do
    @project.repository = { 'topics' => ['bioinformatics', 'genomics'], 'full_name' => 'user/tool' }
    result = ScienceScoreCalculator.new(@project).check_negative_indicators
    refute result[:present]
    assert_equal 0.0, result[:penalty]
  end

  test "negative_indicators penalty is applied to final score" do
    @project.citation_file = 'x'
    @project.readme = 'https://doi.org/10.1234/example'
    base = ScienceScoreCalculator.new(@project).calculate[:score]

    @project.repository = { 'topics' => ['awesome-list'] }
    penalised = ScienceScoreCalculator.new(@project).calculate[:score]

    assert_in_delta base * 0.2, penalised, 0.1
  end

  test "negative_indicators penalty does not apply to JOSS projects" do
    @project.citation_file = 'x'
    @project.joss_metadata = { 'title' => 'x' }
    base = ScienceScoreCalculator.new(@project).calculate[:score]

    @project.repository = { 'topics' => ['tutorial'] }
    penalised = ScienceScoreCalculator.new(@project).calculate[:score]

    assert_equal base, penalised
  end

  test "check_institutional_owner returns false when no website" do
    host = Host.create!(name: 'GitHub')
    owner = Owner.create!(host: host, login: 'someorg', kind: 'organization')
    @project.update(host: host, owner_record: owner)
    @project.update_column(:owner, { 'website' => nil })

    calculator = ScienceScoreCalculator.new(@project)
    result = calculator.check_institutional_owner

    assert_not result[:present]
  end
end
