require "test_helper"

class ProjectImportersTest < ActiveSupport::TestCase
  setup do
    Project.any_instance.stubs(:sync_async)
  end

  # ---- import_from_csv ----

  test "import_from_csv creates projects from remote CSV" do
    csv = "git_url,project_name,oneliner,rubric\nhttps://github.com/Foo/Bar,foo,desc,domain\n,,,\n"
    stub_request(:get, "https://example.com/list.csv").to_return(status: 200, body: csv)

    assert_difference("Project.count", 1) do
      Project.import_from_csv("https://example.com/list.csv")
    end
    p = Project.find_by(url: "https://github.com/foo/bar")
    assert_equal "foo", p.name
    assert_equal "desc", p.description
    assert_equal "domain", p.rubric
  end

  test "import_from_csv returns early on non-success response" do
    stub_request(:get, "https://example.com/list.csv").to_return(status: 500)
    assert_no_difference("Project.count") do
      Project.import_from_csv("https://example.com/list.csv")
    end
  end

  # ---- import_science_csv ----

  test "import_science_csv creates new projects and skips existing" do
    Project.create!(url: "https://github.com/existing/repo")
    Tempfile.create(["science", ".csv"]) do |f|
      f.write("HTML URL\nhttps://github.com/New/Repo\nhttps://github.com/existing/repo\n\n")
      f.flush
      result = nil
      capture_io { result = Project.import_science_csv(f.path, batch_size: 10) }
      assert_equal({ imported: 1, existing: 1, failed: 0 }, result)
    end
    assert Project.exists?(url: "https://github.com/new/repo")
  end

  test "import_science_csv returns nil when file missing" do
    capture_io do
      assert_nil Project.import_science_csv("/nonexistent/path.csv")
    end
  end

  # ---- import_topic / import_keyword / import_org ----

  test "import_topic creates projects from repos api" do
    body = { repositories: [{ html_url: "https://github.com/A/B" }, { html_url: "" }] }.to_json
    stub_request(:get, %r{repos\.ecosyste\.ms/api/v1/topics/astronomy}).to_return(status: 200, body: body)

    assert_difference("Project.count", 1) { Project.import_topic("astronomy") }
    assert Project.exists?(url: "https://github.com/a/b")
  end

  test "import_topic skips existing projects" do
    Project.create!(url: "https://github.com/a/b")
    body = { repositories: [{ html_url: "https://github.com/A/B" }] }.to_json
    stub_request(:get, %r{repos\.ecosyste\.ms/api/v1/topics/astronomy}).to_return(status: 200, body: body)

    assert_no_difference("Project.count") { Project.import_topic("astronomy") }
  end

  test "import_keyword creates projects from packages api and skips packages with status" do
    body = {
      packages: [
        { repository_url: "https://github.com/A/B", status: nil },
        { repository_url: "https://github.com/C/D", status: "removed" },
      ],
    }.to_json
    stub_request(:get, %r{packages\.ecosyste\.ms/api/v1/keywords/astronomy}).to_return(status: 200, body: body)

    assert_difference("Project.count", 1) { Project.import_keyword("astronomy") }
    assert Project.exists?(url: "https://github.com/a/b")
    refute Project.exists?(url: "https://github.com/c/d")
  end

  test "import_org creates projects from host owner repositories" do
    body = [{ html_url: "https://github.com/org/repo" }].to_json
    stub_request(:get, %r{repos\.ecosyste\.ms/api/v1/hosts/GitHub/owners/org/repositories}).to_return(status: 200, body: body)

    assert_difference("Project.count", 1) { Project.import_org("GitHub", "org") }
    assert Project.exists?(url: "https://github.com/org/repo")
  end

  # ---- import_from_github_owner ----

  test "import_from_github_owner paginates until empty and returns stats" do
    Project.create!(url: "https://github.com/scipy/existing")
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/scipy/repositories?page=1")
      .to_return(status: 200, body: [
        { html_url: "https://github.com/SciPy/New" },
        { html_url: "https://github.com/scipy/existing" },
        { html_url: "" },
      ].to_json)
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/scipy/repositories?page=2")
      .to_return(status: 200, body: [].to_json)

    stats = nil
    capture_io { stats = Project.import_from_github_owner("scipy") }
    assert_equal({ created: 1, existing: 1 }, stats)
    assert Project.exists?(url: "https://github.com/scipy/new")
  end

  # ---- import_from_github_topic ----

  test "import_from_github_topic paginates and stops at max_pages" do
    stub_request(:get, "https://repos.ecosyste.ms/api/v1/hosts/GitHub/topics/bio?page=1")
      .to_return(status: 200, body: { repositories: [{ html_url: "https://github.com/x/y" }] }.to_json)

    stats = nil
    capture_io { stats = Project.import_from_github_topic("bio", 1) }
    assert_equal({ created: 1, existing: 0 }, stats)
  end

  # ---- import_from_package_keyword ----

  test "import_from_package_keyword only imports github repos" do
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/keywords/bio?page=1")
      .to_return(status: 200, body: {
        packages: [
          { repository_url: "https://github.com/a/b" },
          { repository_url: "https://gitlab.com/c/d" },
          { repository_url: nil },
        ],
      }.to_json)
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/keywords/bio?page=2")
      .to_return(status: 200, body: { packages: [] }.to_json)

    stats = nil
    capture_io { stats = Project.import_from_package_keyword("bio") }
    assert_equal({ created: 1, existing: 0, skipped: 2 }, stats)
    assert Project.exists?(url: "https://github.com/a/b")
  end

  # ---- import_from_registry + delegators ----

  test "import_from_registry only imports github repos" do
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/registries/cran.r-project.org/packages?page=1")
      .to_return(status: 200, body: [
        { repository_url: "https://github.com/tidyverse/dplyr/" },
        { repository_url: "https://gitlab.com/x/y" },
        { repository_url: nil },
      ].to_json)
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/registries/cran.r-project.org/packages?page=2")
      .to_return(status: 200, body: [].to_json)

    capture_io { Project.import_from_registry("cran.r-project.org", "CRAN") }
    assert Project.exists?(url: "https://github.com/tidyverse/dplyr")
    refute Project.exists?(url: "https://gitlab.com/x/y")
  end

  test "import_from_cran delegates to import_from_registry" do
    Project.expects(:import_from_registry).with("cran.r-project.org", "CRAN")
    Project.import_from_cran
  end

  test "import_from_bioconductor delegates to import_from_registry" do
    Project.expects(:import_from_registry).with("bioconductor.org", "Bioconductor")
    Project.import_from_bioconductor
  end

  test "import_from_conda_forge delegates to import_from_registry" do
    Project.expects(:import_from_registry).with("conda-forge.org", "conda-forge")
    Project.import_from_conda_forge
  end

  # ---- import_from_joss ----

  test "import_from_joss creates new and updates existing with joss_metadata" do
    existing = Project.create!(url: "https://github.com/old/paper")
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=1")
      .to_return(status: 200, body: [
        { software_repository: "https://github.com/New/Paper", title: "New Paper", year: 2024 },
        { software_repository: "https://github.com/Old/Paper", title: "Old Paper", year: 2020 },
        { software_repository: "" },
      ].to_json)
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=2")
      .to_return(status: 200, body: [].to_json)

    capture_io { Project.import_from_joss }
    assert Project.exists?(url: "https://github.com/new/paper")
    assert_equal "Old Paper", existing.reload.joss_metadata["title"]
  end

  # ---- import_from_ost ----

  test "import_from_ost creates github projects only" do
    stub_request(:get, "https://ost.ecosyste.ms/api/v1/projects?reviewed=true&page=1")
      .to_return(status: 200, body: [
        { url: "https://github.com/a/b" },
        { url: "https://gitlab.com/c/d" },
        { url: nil },
      ].to_json)
    stub_request(:get, "https://ost.ecosyste.ms/api/v1/projects?reviewed=true&page=2")
      .to_return(status: 200, body: [].to_json)

    capture_io { Project.import_from_ost }
    assert Project.exists?(url: "https://github.com/a/b")
    refute Project.exists?(url: "https://gitlab.com/c/d")
  end

  # ---- import_from_papers ----

  test "import_from_papers extracts github repository_url from package field" do
    stub_request(:get, "https://papers.ecosyste.ms/api/v1/projects?page=1")
      .to_return(status: 200, body: [
        { package: { repository_url: "https://github.com/a/b" } },
        { package: { repository_url: "https://gitlab.com/c/d" } },
        { package: { repository_url: nil } },
        { package: nil },
      ].to_json)
    stub_request(:get, "https://papers.ecosyste.ms/api/v1/projects?page=2")
      .to_return(status: 200, body: [].to_json)

    capture_io { Project.import_from_papers }
    assert Project.exists?(url: "https://github.com/a/b")
    refute Project.exists?(url: "https://gitlab.com/c/d")
  end

  # ---- top_joss_topics ----

  test "top_joss_topics counts keywords across joss projects" do
    Project.create!(url: "https://github.com/j/1", joss_metadata: { doi: "1" }, keywords: %w[astronomy python bio])
    Project.create!(url: "https://github.com/j/2", joss_metadata: { doi: "2" }, keywords: %w[astronomy bio])
    Project.create!(url: "https://github.com/j/3", joss_metadata: { doi: "3" }, keywords: %w[astronomy])
    Project.create!(url: "https://github.com/j/4", keywords: %w[chemistry])

    assert_equal %w[astronomy bio python], Project.top_joss_topics(3)
  end

  # ---- github_owners ----

  test "github_owners extracts unique lowercased owners above min score" do
    Project.create!(url: "https://github.com/NumPy/numpy", science_score: 50, repository: { full_name: "numpy/numpy" })
    Project.create!(url: "https://github.com/numpy/other", science_score: 50, repository: { full_name: "numpy/other" })
    Project.create!(url: "https://github.com/lowscore/x", science_score: 5, repository: { full_name: "lowscore/x" })
    Project.create!(url: "https://gitlab.com/foo/x", science_score: 50, repository: { full_name: "foo/x" })

    assert_equal ["numpy"], Project.github_owners(20)
  end

  test "scientific_github_owners delegates to github_owners with 20" do
    Project.expects(:github_owners).with(20).returns(["numpy"])
    assert_equal ["numpy"], Project.scientific_github_owners
  end

  # ---- discover_via_* ----

  test "discover_via_topics calls import_topic for each relevant keyword" do
    Project.stubs(:relevant_keywords).returns(%w[astro bio])
    Project.expects(:import_topic).with("astro")
    Project.expects(:import_topic).with("bio")
    Project.discover_via_topics(2)
  end

  test "discover_via_keywords calls import_keyword for each relevant keyword" do
    Project.stubs(:relevant_keywords).returns(%w[astro])
    Project.expects(:import_keyword).with("astro")
    Project.discover_via_keywords(1)
  end

  # ---- import_all_* orchestrators ----

  test "import_all_joss_topics calls import_from_github_topic per topic" do
    Project.stubs(:top_joss_topics).returns(%w[astro])
    Project.stubs(:sleep)
    Project.expects(:import_from_github_topic).with("astro").returns(created: 1, existing: 0)
    capture_io { Project.import_all_joss_topics }
  end

  test "import_all_joss_keywords calls import_from_package_keyword per keyword" do
    Project.stubs(:top_joss_topics).returns(%w[astro])
    Project.stubs(:sleep)
    Project.expects(:import_from_package_keyword).with("astro").returns(created: 1, existing: 0, skipped: 0)
    capture_io { Project.import_all_joss_keywords }
  end

  test "import_all_github_owners calls import_from_github_owner per owner" do
    Project.stubs(:github_owners).returns(%w[numpy])
    Project.stubs(:sleep)
    Project.expects(:import_from_github_owner).with("numpy").returns(created: 1, existing: 0)
    capture_io { Project.import_all_github_owners }
  end
end
