require "test_helper"

class PackageScienceScoreReviewReportTest < ActiveSupport::TestCase
  test "reports score inputs without changing the project" do
    now = Time.zone.parse("2026-08-31 12:00:00")
    registry = PackageRegistry.create!(
      name: "cran.r-project.org",
      url: "https://cran.r-project.org",
      ecosystem: "cran",
      purl_type: "cran",
      default: true
    )
    project = Project.create!(
      url: "https://github.com/test/report-package",
      name: "Report package",
      science_score: 7.5,
      last_synced_at: now - 2.days,
      repository: {
        "metadata" => {
          "files" => {
            "readme" => "README.md",
            "citation" => "CITATION.cff",
            "codemeta" => nil,
          },
        },
      },
      brief: {
        "version" => "0.12.1",
        "languages" => [{ "name" => "R" }],
        "package_managers" => [{ "name" => "R" }],
        "tools" => { "test" => [{ "name" => "testthat" }] },
        "manifests" => [{ "path" => "DESCRIPTION" }],
        "dependencies" => [],
      }
    )
    package = Package.create!(
      package_registry: registry,
      name: "report-package",
      purl: "pkg:cran/report-package",
      published_by_project: project,
      repository_url: project.url,
      ecosystems_sync_status: "matched"
    )
    dependent = Project.create!(
      url: "https://github.com/test/report-dependent",
      science_score: 50
    )
    ProjectDependency.create!(
      project: dependent,
      package: package,
      ecosystem: "cran",
      package_name: package.name,
      purl: package.purl,
      direct: true
    )
    updated_at = project.updated_at

    result = PackageScienceScoreReviewReport.new(
      purls: [package.purl, "pkg:cran/missing"],
      now: now
    ).generate

    package_report, missing_report = result.fetch(:packages)
    assert_equal "reviewed", package_report.fetch(:status)
    assert_equal 1, package_report.fetch(:scientific_projects_count)
    assert_equal 2.0, package_report.dig(:project, :sync_age_days)
    assert_equal({ "readme" => "README.md", "citation" => "CITATION.cff" },
      package_report.dig(:project, :repository_metadata_files))
    assert_equal "collected", package_report.dig(:project, :brief, :status)
    assert_equal ["R"], package_report.dig(:project, :brief, :languages)
    assert_equal ["testthat"], package_report.dig(:project, :brief, :tools, "test")
    assert package_report.dig(:project, :science_score_breakdown).key?(:has_codemeta)
    assert_includes package_report.dig(:project, :missing_positive_signals).pluck(:key),
      :has_codemeta
    assert_equal({ purl: "pkg:cran/missing", status: "package_not_found" },
      missing_report)
    assert_equal 7.5, project.reload.science_score
    assert_equal updated_at, project.updated_at
  end

  test "reports an unlinked package" do
    registry = PackageRegistry.create!(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "unlinked",
      purl: "pkg:pypi/unlinked",
      repository_url: "https://github.com/test/unlinked"
    )

    report = PackageScienceScoreReviewReport.new(
      purls: [package.purl]
    ).generate.fetch(:packages).first

    assert_equal "publishing_project_not_linked", report.fetch(:status)
    assert_nil report.fetch(:project)
    assert_equal package.repository_url, report.dig(:repository_match, :url)
  end

  test "selects current low-scoring candidates when purls are omitted" do
    registry = PackageRegistry.create!(
      name: "cran.r-project.org",
      url: "https://cran.r-project.org",
      ecosystem: "cran",
      purl_type: "cran",
      default: true
    )
    candidate_project = Project.create!(
      url: "https://github.com/test/current-candidate",
      science_score: 12
    )
    candidate = Package.create!(
      package_registry: registry,
      published_by_project: candidate_project,
      name: "current-candidate",
      purl: "pkg:cran/current-candidate",
      average_top_percentage: 5
    )
    popular_general_package = Package.create!(
      package_registry: registry,
      published_by_project: Project.create!(
        url: "https://github.com/test/popular-general",
        science_score: 1
      ),
      name: "popular-general",
      purl: "pkg:cran/popular-general",
      average_top_percentage: 0
    )
    dependents = 2.times.map do |index|
      Project.create!(
        url: "https://github.com/test/candidate-dependent-#{index}",
        science_score: 50
      )
    end
    ProjectDependency.create!(
      project: dependents.first,
      package: candidate,
      ecosystem: "cran",
      package_name: candidate.name,
      purl: candidate.purl,
      direct: true
    )
    dependents.each do |dependent|
      ProjectDependency.create!(
        project: dependent,
        package: popular_general_package,
        ecosystem: "cran",
        package_name: popular_general_package.name,
        purl: popular_general_package.purl,
        direct: true
      )
    end

    result = PackageScienceScoreReviewReport.new(limit: 1).generate

    assert_equal "current_candidates", result.dig(:selection, :mode)
    assert_equal "science_relevance", result.dig(:selection, :order)
    assert_equal [candidate.purl], result.fetch(:packages).pluck(:purl)
  end
end
