require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(
      url: "https://github.com/tidyverse/ggplot2",
      name: "ggplot2",
      description: "An implementation of the Grammar of Graphics in R",
      science_score: 85
    )
    
    @non_science_project = Project.create!(
      url: "https://github.com/example/non-science",
      name: "non-science-project",
      description: "A non-scientific project",
      science_score: 0
    )
  end

  teardown do
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "shows a model project without inventing repository timestamps or service links" do
    registry = PackageRegistry.create!(name: "huggingface.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model",
      metadata: { "name" => "example/model", "latest_release_number" => "a" * 40,
        "dependent_packages_url" => "https://packages.ecosyste.ms/api/v1/registries/huggingface.co/packages/example%2Fmodel/dependent_packages" })
    project = PackageRepository.link!(package)
    project.update!(readme: "# Research model", brief: { "revision" => "a" * 40 }, last_synced_at: Time.current)
    get project_path(project)
    assert_response :success
    assert_select "a[href='https://huggingface.co/example/model']", text: "Repository"
    assert_not_includes response.body, "repos.ecosyste.ms/hosts/HuggingFace.co"
    assert_equal "https://huggingface.co/example/model/resolve/#{'a' * 40}/README.md", project.raw_url("README.md")
  end

  test "should get index" do
    get projects_url
    assert_response :success
  end

  test "shows package and scanned repository metadata through the project page" do
    registry = PackageRegistry.create!(name: "huggingface.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model",
      metadata: { "licenses" => "apache-2.0", "metadata" => { "pipeline_tag" => "feature-extraction", "library_name" => "transformers" } })
    project = PackageRepository.link!(package)
    project.update!(readme: "---\nlanguage: [en, fr]\n---\n# Research encoder\n\nAn encoder for comparing scientific abstracts across several languages.\n",
      brief: { "languages" => [{ "name" => "Python" }] }, last_synced_at: Time.current)
    PackageRepository.link!(package)

    get project_path(project)

    assert_response :success
    assert_select "h1", text: "Research encoder"
    assert_select ".lead", text: "An encoder for comparing scientific abstracts across several languages."
    assert_select "#project-repository", text: /Language: Python/
    assert_select "#project-repository", text: /Supported languages: en, fr/
    assert_select "#project-repository", text: /Tasks: feature-extraction/
    assert_select "#project-repository", text: /Libraries: transformers/
    assert_select "#project-repository", text: /License: apache-2.0/
    assert_select "#project-repository strong", text: "Stars:", count: 0
  end

  test "renders model README body without YAML and keeps adjacent fenced code as code" do
    registry = PackageRegistry.create!(name: "huggingface.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model", metadata: {})
    project = PackageRepository.link!(package)
    readme = "---\nlanguage: en\nwidget:\n  - text: hidden-widget-example\n---\n## SPLADE CoCondenser SelfDistil\n\nLoad this model.\n```python\n# Download from the Hub\nmodel = load_model()\n```\n\n---\n\nVisible body text."
    project.update!(readme: readme, last_synced_at: Time.current,
      repository: project.repository.deep_merge("metadata" => { "files" => { "readme" => "README.md" } }))
    PackageRepository.link!(package)

    get project_path(project)

    assert_response :success
    assert_select "h1", text: "SPLADE CoCondenser SelfDistil"
    assert_select "pre code", text: /# Download from the Hub/
    assert_select "h1", text: "Download from the Hub", count: 0
    assert_select "p", text: "Visible body text."
    assert_not_includes response.body, "hidden-widget-example"
    assert_not_includes response.body, "language: en"
    assert_equal readme, project.reload.readme
  end

  test "shows gated access alongside available package metadata" do
    registry = PackageRegistry.create!(name: "huggingface.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    package = registry.packages.create!(name: "example/gated", purl: "pkg:huggingface/example/gated",
      metadata: { "description" => "A model with restricted access.", "metadata" => { "gated" => "manual" } })
    project = PackageRepository.link!(package)
    SyncProjectWorker.new.perform(project.id)

    get project_path(project)

    assert_response :success
    assert_select "[role='status']", text: /Gated model.*repository scanning is skipped/m
    assert_select ".lead", text: "A model with restricted access."
    assert_equal "gated", project.reload.brief["status"]
  end

  test "index results are sorted by science_score then ranking" do
    project_low = Project.create!(
      url: "https://github.com/test/project-low",
      name: "project-low",
      science_score: 40,
      score: 10
    )

    project_high = Project.create!(
      url: "https://github.com/test/project-high",
      name: "project-high",
      science_score: 60,
      score: 60
    )

    project_medium = Project.create!(
      url: "https://github.com/test/project-medium",
      name: "project-medium",
      science_score: 30,
      score: 60
    )

    get projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_equal [@project, project_high, project_low, project_medium].map(&:id), projects.map(&:id)
  end

  test "should get show" do
    get project_url(@project)
    assert_response :success
  end

  test "show preserves fenced code in markdown readmes" do
    code = "import pooch\n\n# Download a file and save it locally\nfile_name = '<example>'\n"
    @project.update!(
      last_synced_at: Time.current,
      repository: {
        "host" => { "name" => "GitHub" },
        "owner" => "tidyverse",
        "html_url" => @project.url,
        "default_branch" => "main",
        "stargazers_count" => 10,
        "forks_count" => 2,
        "open_issues_count" => 1,
        "topics" => [],
        "created_at" => 1.year.ago.iso8601,
        "metadata" => { "files" => { "readme" => "README.md" } }
      },
      readme: "# Usage\n\n```python\n#{code}```\n"
    )

    get project_url(@project)

    assert_response :success
    assert_select "#project-repository-readme" do
      assert_select "h1", count: 1, text: "Usage"
      assert_select "pre > code.python", count: 1 do |blocks|
        assert_equal code, blocks.first.text
        assert_empty blocks.first.element_children
      end
    end
  end

  test "show displays wiki readmes as plain text" do
    %w[wiki mediawiki].each do |extension|
      @project.update!(
        last_synced_at: Time.current,
        repository: {
          "host" => { "name" => "GitHub" },
          "owner" => "tidyverse",
          "html_url" => @project.url,
          "default_branch" => "main",
          "stargazers_count" => 10,
          "forks_count" => 2,
          "open_issues_count" => 1,
          "topics" => [],
          "created_at" => 1.year.ago.iso8601,
          "metadata" => { "files" => { "readme" => "README.#{extension}" } }
        },
        readme: "== ggplot2 ==\nA plotting library with [[examples]]."
      )

      get project_url(@project)

      assert_response :success
      assert_select "#project-repository-readme pre", text: @project.readme
    end
  end

  test "show organizes project data into tabs and section tabs" do
    @project.update!(
      last_synced_at: Time.current,
      keywords: ["visualization"],
      swhids: swhid_result,
      repository: {
        "host" => { "name" => "GitHub" },
        "owner" => "tidyverse",
        "html_url" => @project.url,
        "default_branch" => "main",
        "stargazers_count" => 10,
        "forks_count" => 2,
        "open_issues_count" => 1,
        "topics" => [],
        "created_at" => 1.year.ago.iso8601,
        "metadata" => {
          "files" => { "readme" => "README.md" },
        },
      },
      readme: "# ggplot2",
      owner: { "name" => "Tidyverse" },
      events: {
        "total" => { "PushEvent" => 10 },
        "last_year" => { "PushEvent" => 4 },
      },
      dependencies: [
        {
          "filepath" => "Gemfile",
          "ecosystem" => "rubygems",
          "kind" => "manifest",
          "dependencies" => [],
        },
      ]
    )

    get project_url(@project)

    assert_response :success
    assert_select "#project-tabs[role='tablist']" do
      assert_select "button[role='tab']", count: 5
      assert_select "#project-overview-tab.active", text: "Overview"
      assert_select "#project-repository-tab", text: "Repository"
      assert_select "#project-research-tab", text: "Research"
      assert_select "#project-activity-tab", text: "Activity"
      assert_select "#project-packages-tab", text: "Packages"
    end
    assert_select "#project-overview.tab-pane.active" do
      assert_select "[data-role='project-keywords']", text: /visualization/
    end
    assert_select "#project-repository" do
      assert_select "#project-repository-tabs button", count: 4
      assert_select "#project-repository-details", text: /Repository/
      assert_select "#project-repository-swhids-tab", text: "SWHIDs"
      assert_select "#project-repository-swhids", text: /swh:1:rev:/
      assert_select "#project-repository-readme h1", text: "ggplot2"
      assert_select "#project-repository-owner", text: /Tidyverse/
    end
    assert_select "#project-activity" do
      assert_select "#project-activity-tabs button", count: 1
      assert_select "#project-activity-events", text: /GitHub Events/
    end
    assert_select "#project-packages" do
      assert_select "#project-packages-tabs button", count: 1
      assert_select "#project-packages-dependencies", text: /Dependencies/
    end
  end

  test "show links normalized JOSS publication authors and editors" do
    @project.update!(
      last_synced_at: Time.current,
      joss_metadata: {
        "doi" => "10.21105/joss.12345",
        "title" => "Example Paper",
        "authors" => [
          {
            "given_name" => "Zoe",
            "last_name" => "Zimmer",
          },
          {
            "given_name" => "Ada",
            "last_name" => "Lovelace",
            "orcid" => "0000-0002-1825-0097",
            "affiliation" => "Example University",
          },
        ],
        "editor_name" => "Grace Hopper",
        "editor_orcid" => "0000-0001-5109-3700",
      }
    )
    JossPublicationIndexer.new(@project).sync!
    AuthorIdentityIndexer.new(@project).sync!
    paper = @project.papers.first
    author_credit = paper.paper_authors.find_by!(
      role: "author",
      display_name: "Ada Lovelace"
    )
    zoe_credit = paper.paper_authors.find_by!(
      role: "author",
      display_name: "Zoe Zimmer"
    )
    editor_credit = paper.paper_authors.find_by!(role: "editor")

    get project_url(@project)

    assert_response :success
    assert_equal [author_credit.id.to_s, zoe_credit.id.to_s],
      css_select(
        "#project-research-joss [data-role='joss-authors'] " \
          "[data-paper-author-id]"
      ).map { |credit| credit["data-paper-author-id"] }
    assert_select "#project-research-joss [data-role='joss-authors']" do
      assert_select "[data-paper-author-id='#{author_credit.id}']" do
        assert_select "a[href='#{author_path(author_credit.author)}']",
          text: "Ada Lovelace"
        assert_select "a[href='https://orcid.org/0000-0002-1825-0097']",
          text: "ORCID"
        assert_select "small", text: "Example University"
      end
    end
    assert_select "[data-role='joss-editors']" do
      assert_select "[data-paper-author-id='#{editor_credit.id}']" do
        assert_select "a[href='#{author_path(editor_credit.author)}']",
          text: "Grace Hopper"
      end
    end
  end

  test "show displays calculated SWHIDs and provenance in the repository section" do
    @project.update!(last_synced_at: Time.current, swhids: swhid_result)

    get project_url(@project)

    assert_response :success
    assert_select "#project-repository-swhids-tab", text: "SWHIDs"
    assert_select "#project-repository-swhids" do
      assert_select "[data-role='swhid-revision'] code", text: "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
      assert_select "[data-role='swhid-directory'] code", text: "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"
      assert_select "[data-role='swhid-revision'] a[href='https://archive.softwareheritage.org/browse/revision/817c61051b31ce4d0eb73d1b873c02de87ce1f81/']", text: "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
      assert_select "[data-role='swhid-directory'] a[href='https://archive.softwareheritage.org/browse/directory/b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0/']", text: "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"
      assert_select "code", text: "817c61051b31ce4d0eb73d1b873c02de87ce1f81"
      assert_select "dd", text: "https://github.com/simonehagey/orbdot"
      assert_select "dt", text: "Calculated"
      assert_select "time[datetime='2026-09-20T12:44:07Z']", text: "September 20, 2026 at 12:44 UTC"
      assert_select "[data-role='swhid-revision-archive'] .badge", text: "Not checked"
      assert_select "[data-role='swhid-directory-archive'] .badge", text: "Not checked"
      assert_select ".alert", count: 0
    end
    assert_not_includes response.body, "/tmp/science-swhid"
  end

  test "show omits the SWHID tab before a scan" do
    @project.update!(last_synced_at: Time.current)

    get project_url(@project)

    assert_response :success
    assert_select "#project-repository-swhids-tab", count: 0
    assert_select "#project-repository-swhids", count: 0
  end

  test "show displays repository coverage before a local scan without making API requests" do
    @project.update!(last_synced_at: Time.current, swhids: {
      "origin_archive" => { "status" => "archived", "checked_at" => "2026-09-22T08:00:00Z" }
    })

    get project_url(@project)

    assert_response :success
    assert_select "[data-role='swhid-origin-archive']", text: /Archived snapshot found/
    assert_select "[data-role='swhid-origin-archive'] time[datetime='2026-09-22T08:00:00Z']"
    assert_select "[data-role='swhid-revision']", text: "Unavailable"
    assert_not_requested :get, /archive\.softwareheritage\.org/
  end

  test "show distinguishes current coverage from repository coverage before submission" do
    @project.update!(last_synced_at: Time.current, swhids: swhid_result.merge(
      "origin_archive" => { "status" => "archived", "checked_at" => "2026-09-22T08:00:00Z" },
      "archival" => { "repository_before_request" => { "classification" => "missing_repository", "basis" => "pre_submission" } }
    ))

    get project_url(@project)

    assert_response :success
    assert_select "[data-role='swhid-origin-archive']", text: /Archived snapshot found/
    assert_select "[data-role='swhid-request-classification']", text: /No repository snapshot found before submission/
  end

  test "show labels classifications inferred from historical visits" do
    @project.update!(last_synced_at: Time.current, swhids: swhid_result.merge(
      "archival" => { "repository_before_request" => { "classification" => "missing_versions", "basis" => "visit_history" } }
    ))

    get project_url(@project)

    assert_response :success
    assert_select "[data-role='swhid-request-classification']", text: /Missing version of an archived repository/
    assert_select "[data-role='swhid-request-classification'] .text-muted", text: "Inferred from historical visit dates"
  end

  test "show displays cached archive coverage for each identifier" do
    result = swhid_result
    result["revision"]["archive"] = { "status" => "archived", "checked_at" => "2026-09-20T12:45:00Z" }
    result["directory"]["archive"] = { "status" => "not_found", "checked_at" => "2026-09-20T12:45:00Z" }
    @project.update!(last_synced_at: Time.current, swhids: result)

    get project_url(@project)

    assert_response :success
    assert_select "[data-role='swhid-revision-archive']" do
      assert_select ".badge", text: "Archived"
      assert_select "time[datetime='2026-09-20T12:45:00Z']"
    end
    assert_select "[data-role='swhid-directory-archive'] .badge", text: "Not found"
  end

  test "show distinguishes a failed archive check from a missing object" do
    result = swhid_result
    result["revision"]["archive"] = { "status" => "error", "attempted_at" => "2026-09-20T12:45:00Z", "error" => "HTTP 429" }
    @project.update!(last_synced_at: Time.current, swhids: result)

    get project_url(@project)

    assert_response :success
    assert_select "[data-role='swhid-revision-archive']" do
      assert_select ".badge", text: "Check failed"
      assert_select "time[datetime='2026-09-20T12:45:00Z']"
    end
    assert_select "[data-role='swhid-directory-archive'] .badge", text: "Not checked"
    assert_not_includes response.body, "HTTP 429"
  end

  test "show handles a failed clone without exposing command diagnostics" do
    @project.update!(last_synced_at: Time.current, swhids: {
      "status" => "error",
      "origin" => @project.url,
      "attempted_at" => "2026-09-20T12:44:07Z",
      "error" => "fatal: /tmp/science-swhid/repository: permission denied"
    })

    get project_url(@project)

    assert_response :success
    assert_select "#project-repository-swhids" do
      assert_select ".alert-warning", text: "SWHID calculation did not complete."
      assert_select "[data-role='swhid-revision']", text: "Unavailable"
      assert_select "[data-role='swhid-directory']", text: "Unavailable"
      assert_select "dt", text: "Last attempted"
      assert_select "a", count: 0
    end
    assert_not_includes response.body, "permission denied"
    assert_not_includes response.body, "/tmp/science-swhid"
  end

  test "show retains a successful revision when directory calculation fails" do
    result = swhid_result
    result["status"] = "error"
    result["directory"] = { "status" => "error", "error" => "command timed out" }
    @project.update!(last_synced_at: Time.current, swhids: result)

    get project_url(@project)

    assert_response :success
    assert_select "#project-repository-swhids" do
      assert_select ".alert-warning"
      assert_select "[data-role='swhid-revision'] code", text: result.dig("revision", "swhid")
      assert_select "[data-role='swhid-directory']", text: "Unavailable"
      assert_select "[data-role='swhid-revision'] a[href='https://archive.softwareheritage.org/browse/revision/817c61051b31ce4d0eb73d1b873c02de87ce1f81/']", text: result.dig("revision", "swhid")
      assert_select "[data-role='swhid-directory'] a", count: 0
    end
  end

  def swhid_result
    {
      "status" => "success",
      "commit" => "817c61051b31ce4d0eb73d1b873c02de87ce1f81",
      "origin" => "https://github.com/simonehagey/orbdot",
      "attempted_at" => "2026-09-20T12:44:07Z",
      "duration_ms" => 1451,
      "revision" => {
        "status" => "success",
        "swhid" => "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81",
        "binary_version" => "swhid 0.1.0",
        "input" => { "path" => "/tmp/science-swhid/repository" }
      },
      "directory" => {
        "status" => "success",
        "swhid" => "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0",
        "binary_version" => "swhid 0.1.0"
      }
    }
  end

  test "show sorts raw JOSS publication authors alphabetically" do
    @project.update!(
      last_synced_at: Time.current,
      joss_metadata: {
        "title" => "Unindexed Paper",
        "authors" => [
          { "given_name" => "Zoe", "last_name" => "Zimmer" },
          { "given_name" => "ada", "last_name" => "Lovelace" },
          { "given_name" => "Charles", "last_name" => "Babbage" },
        ],
      }
    )

    get project_url(@project)

    assert_response :success
    assert_equal ["ada Lovelace", "Charles Babbage", "Zoe Zimmer"],
      css_select("#project-research-joss h6").find { |heading| heading.text == "Authors" }
        .parent.css("div.mb-2")
        .map { |author| author.text.squish }
  end

  test "hidden owner project returns 404 from html and api" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(host: host, login: "hidden-owner")
    project = Project.create!(
      host: host,
      owner_record: owner,
      url: "https://github.com/hidden-owner/project",
      science_score: 50
    )
    owner.update!(hidden: true)

    get project_url(project)
    assert_response :not_found

    get api_v1_project_url(project), as: :json
    assert_response :not_found
  end

  test "should get search" do
    get search_projects_url
    assert_response :success
  end

  test "should search by query" do
    get search_projects_url, params: { q: "ggplot2" }
    assert_response :success
    assert_select ".alert-info", false, "Should find results"
  end

  test "should show no results message for empty search" do
    get search_projects_url, params: { q: "nonexistentproject123" }
    assert_response :success
    assert_select ".alert-info", text: /No projects found/
  end

  test "should search by keywords" do
    @project.update(keywords: ["visualization", "graphics"])
    get search_projects_url, params: { keywords: "visualization" }
    assert_response :success
  end

  test "should search by language" do
    @project.update(repository: { "language" => "R" })
    get search_projects_url, params: { language: "R" }
    assert_response :success
  end

  test "should get lookup" do
    get lookup_projects_url
    assert_response :success
  end

  test "should lookup projects by query" do
    get lookup_projects_url, params: { q: "ggplot2" }
    assert_response :success
    assert_select ".list-group-item", minimum: 1
  end

  test "listings and lookup use the repository slug when the name is missing" do
    project = Project.create!(
      url: "https://github.com/test/unnamed-project-listing",
      science_score: 60
    )

    get projects_url

    assert_response :success
    assert_select "h3 a[href='#{project_path(project)}']" do |links|
      assert_includes links.first.text, "unnamed-project-listing"
      assert_not_includes links.first.text, project.url
    end

    get lookup_projects_url, params: { q: "unnamed-project-listing" }

    assert_response :success
    assert_select "h6", text: "unnamed-project-listing"
  end

  test "listings lookup and project pages use the README heading when the name is missing" do
    project = Project.create!(
      url: "https://github.com/ssec-jhu/levseq-dash",
      science_score: 67,
      readme: "```python\n# Example code\n```\n\n# [LevSeq **Dashboard**](https://example.org) ![Build](badge.svg)\n"
    )

    get projects_url

    assert_response :success
    assert_select "h3 a[href='#{project_path(project)}']" do |links|
      assert_includes links.first.text, "LevSeq Dashboard"
      assert_not_includes links.first.text, project.url
      assert_not_includes links.first.text, "Example code"
    end

    get lookup_projects_url, params: { q: "levseq-dash" }

    assert_response :success
    assert_select "h6", text: "LevSeq Dashboard"

    get project_url(project)

    assert_response :success
    assert_select "h1.mb-3", text: "LevSeq Dashboard"
    assert_nil project.reload.name
  end

  test "should show popular projects when no query" do
    get lookup_projects_url
    assert_response :success
    assert_select ".card-title", text: "Popular Scientific Projects"
  end

  test "should get packages" do
    get packages_projects_url
    assert_response :success
  end

  test "packages paginates download rankings before loading projects" do
    rows = 25.times.map do |i|
      { url: "https://github.com/test/packages-#{i}", name: "Package project #{i}", science_score: 8,
        packages: [{ 'name' => "pkg-#{i}", 'downloads' => (i.zero? ? nil : 25 - i), 'registry' => { 'name' => 'npm' } },
                   { 'name' => "extra-#{i}", 'downloads' => 3 * i, 'registry' => { 'name' => 'npm' } }] }
    end
    ids = Project.insert_all!(rows, returning: %w[id]).rows.flatten
    @project.update_columns(packages: [])
    @non_science_project.update_columns(packages: rows.last[:packages])
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "hidden-packages", hidden: true)
    Project.insert_all!([{ url: "https://github.com/hidden/packages", owner_id: owner.id, science_score: 100,
                          packages: [{ 'downloads' => 10000 }] }])

    instantiated = 0
    subscriber = lambda do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      instantiated += event.payload[:record_count] if event.payload[:class_name] == 'Project'
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'instantiation.active_record') do
      get packages_projects_url
    end
    assert_response :success
    assert_equal ids.reverse.first(20), assigns(:projects).map(&:id)
    assert_equal 20, instantiated
    assert_select '.card.project', count: 20
    assert_select 'a[href*="page=2"]'

    get packages_projects_url, params: { page: 2 }
    assert_response :success
    assert_equal ids.reverse.last(5), assigns(:projects).map(&:id)
    assert_select '.card.project', count: 5
  end

  test "index sorts by allowlisted column" do
    low = Project.create!(url: "https://github.com/test/low-score", science_score: 25)
    get projects_url, params: { sort: 'science_score', order: 'asc' }
    assert_response :success
    projects = assigns(:projects)
    assert_equal low.id, projects.first.id
  end

  test "index falls back to science_score for unknown sort column" do
    get projects_url, params: { sort: 'pg_sleep(1)', order: 'nope' }
    assert_response :success
    sql = assigns(:scope).to_sql
    assert_match 'ORDER BY science_score DESC NULLS LAST', sql
    assert_no_match 'pg_sleep', sql
  end

  test "index only shows projects with science_score > 0" do
    get projects_url
    assert_response :success
    # The index action filters for science_score > 0
    # so non_science_project should not appear
  end

  test "index filters projects by classified research organization owners" do
    create_research_organization_domain("research.example", source: "ror", version: "projects-controller")
    create_research_organization_domain("manual.example", source: "manual", version: "projects-controller")
    ResearchOrganizationDomainMatcher.reset_cache!

    host = Host.create!(name: "GitHub", url: "https://github.com")
    ror_owner = Owner.create!(host: host, login: "ror-owner", kind: "organization", website: "https://research.example")
    manual_owner = Owner.create!(host: host, login: "manual-owner", kind: "organization", website: "https://manual.example")
    other_owner = Owner.create!(host: host, login: "other-owner", kind: "organization", website: "https://other.example")
    ror_project = Project.create!(url: "https://github.com/ror-owner/project", owner_record: ror_owner, science_score: 50)
    manual_project = Project.create!(url: "https://github.com/manual-owner/project", owner_record: manual_owner, science_score: 50)
    Project.create!(url: "https://github.com/other-owner/project", owner_record: other_owner, science_score: 50)

    get projects_url, params: { research_organization: "true" }

    assert_response :success
    projects = assigns(:projects).to_a
    assert_equal 2, projects.length
    assert_includes projects, ror_project
    assert_includes projects, manual_project
    assert_select "a.btn-primary[aria-pressed='true']", text: "Research organizations"
  end

  test "search with pagination" do
    # Create multiple projects for pagination testing
    20.times do |i|
      Project.create!(
        url: "https://github.com/test/project#{i}",
        name: "test-project-#{i}",
        science_score: 50
      )
    end

    get search_projects_url, params: { q: "test" }
    assert_response :success
    # Should have pagination if more than 20 results
  end

  test "search results are sorted by combined science_score and ranking" do
    # Simulates root_numpy: high science (95) but low ranking (7.7) = 102.7
    root_numpy = Project.create!(
      url: "https://github.com/scikit-hep/root_numpy",
      name: "root_numpy",
      science_score: 95,
      score: 7.7
    )

    # Simulates main numpy: medium science (75) but high ranking (40) = 115
    numpy = Project.create!(
      url: "https://github.com/numpy/numpy",
      name: "numpy",
      science_score: 75,
      score: 40
    )

    # Low combined score
    other_numpy = Project.create!(
      url: "https://github.com/other/numpy",
      name: "numpy-other",
      science_score: 65,
      score: 5
    )

    get search_projects_url, params: { q: "numpy" }
    assert_response :success

    projects = assigns(:projects)

    assert_equal 3, projects.length
    # numpy should be first (75 + 40 = 115)
    assert_equal numpy.id, projects[0].id
    # root_numpy should be second (95 + 7.7 = 102.7)
    assert_equal root_numpy.id, projects[1].id
    # other_numpy should be third (65 + 5 = 70)
    assert_equal other_numpy.id, projects[2].id
  end

  test "search filters out projects with zero science_score" do
    project_with_score = Project.create!(
      url: "https://github.com/test/zeroscore",
      name: "zeroscore-project",
      science_score: 50
    )

    project_zero = Project.create!(
      url: "https://github.com/zero/zeroscore",
      name: "zeroscore-zero",
      science_score: 0
    )

    get search_projects_url, params: { q: "zeroscore" }
    assert_response :success

    projects = assigns(:projects)

    assert_equal 1, projects.length
    assert_equal project_with_score.id, projects.first.id
  end

  test "should get joss" do
    get joss_projects_url
    assert_response :success
  end

  test "joss lists only projects with joss_metadata" do
    joss_project = Project.create!(
      url: "https://github.com/test/joss-project",
      name: "joss-project",
      science_score: 85,
      joss_metadata: { "doi" => "10.21105/joss.12345" }
    )

    non_joss_project = Project.create!(
      url: "https://github.com/test/non-joss",
      name: "non-joss",
      science_score: 60
    )

    get joss_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_includes projects, joss_project
    assert_not_includes projects, non_joss_project
  end

  test "joss projects are sorted by combined score" do
    joss_low = Project.create!(
      url: "https://github.com/test/joss-low",
      name: "joss-low",
      science_score: 85,
      score: 5,
      joss_metadata: { "doi" => "10.21105/joss.00001" }
    )

    joss_high = Project.create!(
      url: "https://github.com/test/joss-high",
      name: "joss-high",
      science_score: 85,
      score: 50,
      joss_metadata: { "doi" => "10.21105/joss.00002" }
    )

    get joss_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_equal joss_high.id, projects.first.id
    assert_equal joss_low.id, projects.second.id
  end

  test "should export project with citation_file to bibtex" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      message: "If you use this software, please cite it as below."
      title: "ggplot2"
      authors:
        - family-names: "Wickham"
          given-names: "Hadley"
    CFF
    @project.update(citation_file: cff_content)

    get export_project_url(@project), params: { format: 'bibtex' }

    assert_response :success
    assert_equal 'application/x-bibtex', response.media_type
    assert_match(/@software/, response.body)
  end

  test "should export project with citation_file to apalike" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      message: "If you use this software, please cite it as below."
      title: "ggplot2"
      authors:
        - family-names: "Wickham"
          given-names: "Hadley"
    CFF
    @project.update(citation_file: cff_content)

    get export_project_url(@project), params: { format: 'apalike' }

    assert_response :success
    assert_equal 'text/plain', response.media_type
  end

  test "should return not found for project without citation metadata" do
    get export_project_url(@project), params: { format: 'bibtex' }

    assert_response :not_found
  end

  test "should support bibtex and apalike export formats" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      message: "If you use this software, please cite it as below."
      title: "ggplot2"
      authors:
        - family-names: "Wickham"
          given-names: "Hadley"
    CFF
    @project.update(citation_file: cff_content)

    %w[bibtex apalike].each do |format|
      get export_project_url(@project), params: { format: format }
      assert_response :success
    end
  end

  test "should get codemeta" do
    get codemeta_projects_url
    assert_response :success
  end

  test "codemeta lists only projects with codemeta file in repository metadata" do
    project_with_codemeta = Project.create!(
      url: "https://github.com/test/codemeta-project",
      name: "codemeta-project",
      science_score: 85,
      codemeta: "{}",
      repository: { "metadata" => { "files" => { "codemeta" => "codemeta.json" } } }
    )

    project_without_codemeta = Project.create!(
      url: "https://github.com/test/no-codemeta",
      name: "no-codemeta",
      science_score: 60,
      repository: { "metadata" => { "files" => {} } }
    )

    get codemeta_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_includes projects, project_with_codemeta
    assert_not_includes projects, project_without_codemeta
  end

  test "codemeta projects are sorted by combined score" do
    codemeta_low = Project.create!(
      url: "https://github.com/test/codemeta-low",
      name: "codemeta-low",
      science_score: 85,
      score: 5,
      codemeta: "{}",
      repository: { "metadata" => { "files" => { "codemeta" => "codemeta.json" } } }
    )

    codemeta_high = Project.create!(
      url: "https://github.com/test/codemeta-high",
      name: "codemeta-high",
      science_score: 85,
      score: 50,
      codemeta: "{}",
      repository: { "metadata" => { "files" => { "codemeta" => "codemeta.json" } } }
    )

    get codemeta_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_equal codemeta_high.id, projects.first.id
    assert_equal codemeta_low.id, projects.second.id
  end

  test "should get citation" do
    get citation_projects_url
    assert_response :success
  end

  test "citation lists only projects with citation_file" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Test Project"
      authors:
        - family-names: "Doe"
          given-names: "John"
    CFF

    project_with_citation = Project.create!(
      url: "https://github.com/test/citation-project",
      name: "citation-project",
      science_score: 85,
      citation_file: cff_content
    )

    project_without_citation = Project.create!(
      url: "https://github.com/test/no-citation",
      name: "no-citation",
      science_score: 60
    )

    get citation_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_includes projects, project_with_citation
    assert_not_includes projects, project_without_citation
  end

  test "citation projects are sorted by combined score" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Test"
      authors:
        - family-names: "Test"
          given-names: "Test"
    CFF

    citation_low = Project.create!(
      url: "https://github.com/test/citation-low",
      name: "citation-low",
      science_score: 85,
      score: 5,
      citation_file: cff_content
    )

    citation_high = Project.create!(
      url: "https://github.com/test/citation-high",
      name: "citation-high",
      science_score: 85,
      score: 50,
      citation_file: cff_content
    )

    get citation_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_equal citation_high.id, projects.first.id
    assert_equal citation_low.id, projects.second.id
  end

  test "should get codemeta_csv" do
    Project.create!(
      url: "https://github.com/test/csv-codemeta",
      name: "csv-codemeta",
      science_score: 85,
      codemeta: "{}",
      repository: { "metadata" => { "files" => { "codemeta" => "codemeta.json" } } }
    )

    get codemeta_csv_projects_url
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_match(/repository_url,codemeta_file_path/, response.body)
  end

  test "codemeta_csv includes repository url and file path" do
    project = Project.create!(
      url: "https://github.com/test/csv-codemeta-check",
      name: "csv-codemeta-check",
      science_score: 85,
      codemeta: "{}",
      repository: { "full_name" => "test/csv-codemeta-check", "metadata" => { "files" => { "codemeta" => "codemeta.json" } } }
    )

    get codemeta_csv_projects_url
    assert_response :success
    assert_match(/codemeta\.json/, response.body)
  end

  test "should get citation_csv" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Test"
      authors:
        - family-names: "Test"
          given-names: "Test"
    CFF

    Project.create!(
      url: "https://github.com/test/csv-citation",
      name: "csv-citation",
      science_score: 85,
      citation_file: cff_content,
      repository: { "metadata" => { "files" => { "citation" => "CITATION.cff" } } }
    )

    get citation_csv_projects_url
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_match(/repository_url,citation_file_path/, response.body)
  end

  test "citation_csv includes repository url and file path" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Test"
      authors:
        - family-names: "Test"
          given-names: "Test"
    CFF

    project = Project.create!(
      url: "https://github.com/test/csv-citation-check",
      name: "csv-citation-check",
      science_score: 85,
      citation_file: cff_content,
      repository: { "full_name" => "test/csv-citation-check", "metadata" => { "files" => { "citation" => "CITATION.cff" } } }
    )

    get citation_csv_projects_url
    assert_response :success
    assert_match(/CITATION\.cff/, response.body)
  end

  test "should get zenodo" do
    get zenodo_projects_url
    assert_response :success
  end

  test "zenodo lists only projects with zenodo file in repository metadata" do
    project_with_zenodo = Project.create!(
      url: "https://github.com/test/zenodo-project",
      name: "zenodo-project",
      science_score: 85,
      zenodo: "{}",
      repository: { "metadata" => { "files" => { "zenodo" => ".zenodo.json" } } }
    )

    project_without_zenodo = Project.create!(
      url: "https://github.com/test/no-zenodo",
      name: "no-zenodo",
      science_score: 60,
      repository: { "metadata" => { "files" => {} } }
    )

    get zenodo_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_includes projects, project_with_zenodo
    assert_not_includes projects, project_without_zenodo
  end

  test "zenodo projects are sorted by combined score" do
    zenodo_low = Project.create!(
      url: "https://github.com/test/zenodo-low",
      name: "zenodo-low",
      science_score: 85,
      score: 5,
      zenodo: "{}",
      repository: { "metadata" => { "files" => { "zenodo" => ".zenodo.json" } } }
    )

    zenodo_high = Project.create!(
      url: "https://github.com/test/zenodo-high",
      name: "zenodo-high",
      science_score: 85,
      score: 50,
      zenodo: "{}",
      repository: { "metadata" => { "files" => { "zenodo" => ".zenodo.json" } } }
    )

    get zenodo_projects_url
    assert_response :success

    projects = assigns(:projects)

    assert_equal zenodo_high.id, projects.first.id
    assert_equal zenodo_low.id, projects.second.id
  end

  test "should get zenodo_csv" do
    Project.create!(
      url: "https://github.com/test/csv-zenodo",
      name: "csv-zenodo",
      science_score: 85,
      zenodo: "{}",
      repository: { "metadata" => { "files" => { "zenodo" => ".zenodo.json" } } }
    )

    get zenodo_csv_projects_url
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_match(/repository_url,zenodo_file_path/, response.body)
  end

  test "zenodo_csv includes repository url and file path" do
    project = Project.create!(
      url: "https://github.com/test/csv-zenodo-check",
      name: "csv-zenodo-check",
      science_score: 85,
      zenodo: "{}",
      repository: { "full_name" => "test/csv-zenodo-check", "metadata" => { "files" => { "zenodo" => ".zenodo.json" } } }
    )

    get zenodo_csv_projects_url
    assert_response :success
    assert_match(/\.zenodo\.json/, response.body)
  end
end
