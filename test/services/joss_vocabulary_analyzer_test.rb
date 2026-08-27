require "test_helper"

class JossVocabularyAnalyzerTest < ActiveSupport::TestCase
  def setup
    JossVocabularyAnalyzer.reset_cache!
  end

  test "tokenizer keeps mixed identifiers and rejects standalone numbers" do
    terms = JossVocabularyAnalyzer.terms_from_text(
      "Published in JOSS 2021: mpi4py hdf5 21105. Read the Statement of Need and Community Guidelines."
    )

    assert_includes terms, "mpi4py"
    assert_includes terms, "hdf5"
    refute_includes terms, "21105"
    refute_includes terms, "published"
    refute_includes terms, "joss"
    refute_includes terms, "statement_need"
    refute_includes terms, "community_guidelines"
  end

  test "tokenizer removes badges code and non-scientific sections" do
    project = Project.new(
      url: "https://github.com/test/plasma",
      name: "Plasma solver",
      readme: <<~README
        ![build](https://img.shields.io/build.svg)
        A magnetohydrodynamics simulation using mpi4py.

        ```ruby
        hidden_code_token
        ```

        ## Installation
        hidden_install_token

        ## Usage
        finite element mesh
      README
    )

    terms = JossVocabularyAnalyzer.tokens(project)

    assert_includes terms, "magnetohydrodynamics"
    assert_includes terms, "mpi4py"
    assert_includes terms, "finite_element"
    refute_includes terms, "usage"
    refute_includes terms, "hidden_code"
    refute_includes terms, "hidden_install"
    refute_includes terms, "shields"
  end

  test "tokenizer keeps research sections and removes heading and template text" do
    project = Project.new(
      url: "https://github.com/test/sections",
      readme: <<~README
        Statement of Need
        -----------------
        A plasma simulation for stellar evolution.

        ## Community Guidelines
        hidden_community_token

        ### Contributing
        hidden_contribution_token

        ## Results
        A spectral solver for galaxy evolution.

        ## How to cite
        hidden_citation_token
        - Example, (2025). Journal of Open Source Software, 10(110), 8199, https://doi.org/10.21105/joss.08199
        - @article{Example2025, publisher = {The Open Journal}, volume = {10}, pages = {8199}}

        ## Original paper
        The method models anisotropic turbulence.
      README
    )

    terms = JossVocabularyAnalyzer.tokens(project)

    assert_includes terms, "plasma_simulation"
    assert_includes terms, "spectral_solver"
    assert_includes terms, "anisotropic_turbulence"
    refute_includes terms, "statement_need"
    refute_includes terms, "community_guidelines"
    refute_includes terms, "hidden_community"
    refute_includes terms, "hidden_contribution"
    refute_includes terms, "hidden_citation"
    refute_includes terms, "publisher_the"
    refute_includes terms, "journal_volume"
  end

  test "tokenizer scrubs invalid UTF-8" do
    invalid_readme = "plasma \xE6 simulation".b.force_encoding("UTF-8")
    project = Project.new(url: "https://github.com/test/invalid", readme: invalid_readme)

    assert_includes JossVocabularyAnalyzer.tokens(project), "simulation"
  end

  test "analyze_project scores the strongest three model terms" do
    model = create_model(
      "plasma" => 2.0,
      "simulation" => 1.5,
      "mpi4py" => 1.0,
      "solver" => 0.5
    )
    project = Project.new(
      url: "https://github.com/test/plasma",
      description: "Plasma simulation solver using mpi4py"
    )

    analysis = JossVocabularyAnalyzer.analyze_project(project)

    assert_equal model.id, analysis[:model_id]
    assert_equal %w[plasma simulation mpi4py], analysis[:terms]
    assert_equal 33.75, analysis[:score]
  end

  test "analyze_project counts overlapping terms as one piece of evidence" do
    create_model(
      "source_python" => 2.0,
      "python_package" => 1.8,
      "package_for" => 1.7,
      "astrophysics" => 1.0
    )
    project = Project.new(
      url: "https://github.com/test/python-package",
      description: "An open source Python package for tabular data"
    )

    analysis = JossVocabularyAnalyzer.analyze_project(project)

    assert_equal ["source_python"], analysis[:terms]
    assert_equal 15.0, analysis[:score]
  end

  test "analyze_project ignores generic documentation text and RST image directives" do
    create_model(
      "image_target" => 3.0,
      "readthedocs" => 3.0,
      "solver_documentation" => 3.0,
      "julia_versions" => 3.0,
      "plasma" => 2.0
    )
    project = Project.new(
      url: "https://github.com/test/documentation",
      readme: <<~README
        .. image:: https://readthedocs.org/projects/example/badge/
           :target: https://example.readthedocs.io/

        Solver documentation supports Julia versions. Plasma.
      README
    )

    analysis = JossVocabularyAnalyzer.analyze_project(project)

    assert_equal ["plasma"], analysis[:terms]
    assert_equal 15.0, analysis[:score]
  end

  test "worker memoizes the parsed model" do
    model = create_model("simulation" => 2.0)
    JossVocabularyAnalyzer.reset_cache!
    JossVocabularyModel.expects(:latest).once.returns(model)
    project = Project.new(url: "https://github.com/test/model", readme: "simulation")

    2.times { JossVocabularyAnalyzer.analyze_project(project) }
  end

  test "missing model returns an empty analysis" do
    JossVocabularyModel.delete_all
    JossVocabularyAnalyzer.reset_cache!

    analysis = JossVocabularyAnalyzer.analyze_project(Project.new(url: "https://github.com/test/empty"))

    assert_equal 0.0, analysis[:score]
    assert_nil analysis[:model_id]
    assert_empty analysis[:terms]
  end

  test "worker retries an empty model cache after a short interval" do
    model = create_model("simulation" => 2.0)
    JossVocabularyModel.expects(:latest).twice.returns(nil, model)
    project = Project.new(url: "https://github.com/test/retry", readme: "simulation")

    first = JossVocabularyAnalyzer.analyze_project(project)
    JossVocabularyAnalyzer.instance_variable_set(
      :@cache_checked_at,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - JossVocabularyAnalyzer::EMPTY_MODEL_CACHE_DURATION - 1
    )
    second = JossVocabularyAnalyzer.analyze_project(project)

    assert_nil first[:model_id]
    assert_equal model.id, second[:model_id]
  end

  test "build_model derives terms from JOSS project text and background readmes" do
    joss_projects = 12.times.map do |index|
      Project.create!(
        url: "https://github.com/test/joss-#{index}",
        readme: "Plasma physics simulation",
        joss_metadata: { "tags" => "unrelated metadata" }
      )
    end
    background_projects = 3.times.map do |index|
      Project.create!(
        url: "https://github.com/test/background-#{index}",
        readme: "Web application task manager"
      )
    end

    attributes = JossVocabularyAnalyzer.build_model(
      joss_scope: Project.where(id: joss_projects.map(&:id)),
      background_scope: Project.where(id: background_projects.map(&:id))
    )

    assert_equal 12, attributes[:source_counts][:joss_projects]
    assert_equal 3, attributes[:source_counts][:background_projects]
    assert attributes[:term_weights].key?("plasma")
    refute attributes[:term_weights].key?("unrelated")
    refute attributes[:term_weights].key?("21105")
  end

  def create_model(term_weights)
    JossVocabularyModel.create!(
      term_weights: term_weights,
      config: { "top_terms" => 3, "evidence_threshold" => 4.0 },
      source_counts: { "joss_projects" => 2, "background_projects" => 3 }
    ).tap { JossVocabularyAnalyzer.reset_cache! }
  end
end
