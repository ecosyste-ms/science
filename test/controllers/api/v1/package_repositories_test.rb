require "test_helper"

class Api::V1::PackageRepositoriesTest < ActionDispatch::IntegrationTest
  setup do
    registry = PackageRegistry.create!(name: "huggingface.co", url: "https://huggingface.co",
      ecosystem: "huggingface", purl_type: "huggingface")
    @package = Package.create!(package_registry: registry, name: "Qwen/Qwen3-Embedding-0.6B",
      purl: "pkg:huggingface/Qwen/Qwen3-Embedding-0.6B")
    @project = Project.create!(url: "https://github.com/qwenlm/qwen3-embedding")
    @runtime = Project.create!(url: "https://github.com/huggingface/text-embeddings-inference")
    @card_evidence = { "source" => "model_card", "url" => "https://huggingface.co/#{@package.name}/blob/#{'a' * 40}/README.md",
      "revision" => 'a' * 40, "passage" => "Qwen3 Embedding paper and code" }
    @repo_evidence = { "source" => "repository_review", "url" => "#{@project.url}/blob/#{'b' * 40}/README.md",
      "commit" => 'b' * 40, "line" => 10, "passage" => "Citation for Qwen3 Embedding" }
    @paper = Paper.create!(openalex_id: "https://openalex.org/W12345", title: "Qwen3 Embedding")
    PackagePaper.create!(package: @package, paper: @paper, role: "model_family_paper", evidence: [@card_evidence])
    ProjectPaper.create!(project: @project, paper: @paper, evidence: [@repo_evidence])
    PackageProject.create!(package: @package, project: @runtime, role: "supported_runtime", evidence: [@card_evidence])
  end

  test "returns reviewed paper and runtime paths without writes network requests or jobs" do
    original = @package.attributes
    jobs = Sidekiq::Worker.jobs.deep_dup
    assert_no_difference ["Package.count", "Project.count", "Paper.count", "PackagePaper.count", "ProjectPaper.count", "PackageProject.count", "Mention.count"] do
      get repositories_api_v1_package_url(@package)
    end

    assert_response :success
    assert_equal [@project.id, @runtime.id], response.parsed_body.pluck("id")
    assert_equal "2", response.headers.fetch("total-count")
    paper_link = response.parsed_body.first.fetch("relationships").sole
    assert_equal "paper", paper_link.fetch("type")
    assert_equal "model_family_paper", paper_link.fetch("role")
    assert_equal @paper.openalex_id, paper_link.dig("paper", "openalex_id")
    assert_equal @paper.title, paper_link.dig("paper", "title")
    assert_equal [@card_evidence], paper_link.fetch("package_evidence")
    assert_equal [@repo_evidence], paper_link.fetch("project_evidence")
    assert_equal [{ "type" => "direct", "role" => "supported_runtime", "evidence" => [@card_evidence] }],
      response.parsed_body.last.fetch("relationships")
    assert_equal original, @package.reload.attributes
    assert_nil @package.repository_url
    assert_nil @package.published_by_project_id
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /.*/
  end

  test "groups direct roles and paper paths without duplicating repositories or leaking another package evidence" do
    %w[model_implementation inference_implementation model_library].each do |role|
      PackageProject.create!(package: @package, project: @project, role: role, evidence: [@repo_evidence])
    end
    other_package = Package.create!(package_registry: @package.package_registry, name: "other", purl: "pkg:huggingface/other")
    PackagePaper.create!(package: other_package, paper: @paper, role: "model_paper", evidence: [@repo_evidence])
    PackagePaper.create!(package: @package, paper: @paper, role: "model_paper", evidence: [@card_evidence])

    get repositories_api_v1_package_url(@package)

    assert_response :success
    assert_equal [@project.id, @runtime.id], response.parsed_body.pluck("id")
    links = response.parsed_body.first.fetch("relationships")
    assert_equal %w[model_implementation inference_implementation model_library model_family_paper model_paper], links.pluck("role")
    assert_equal [[@card_evidence], [@card_evidence]], links.select { |link| link["type"] == "paper" }.pluck("package_evidence")
  end

  test "does not treat base model method training or evaluation citations as model repository links" do
    PackagePaper::ROLES.excluding(*PackagePaper::MODEL_ROLES).each_with_index do |role, index|
      paper = Paper.create!(openalex_id: "https://openalex.org/W#{index + 100}")
      project = Project.create!(url: "https://github.com/example/#{role}")
      PackagePaper.create!(package: @package, paper: paper, role: role, evidence: [@card_evidence])
      ProjectPaper.create!(project: project, paper: paper, evidence: [@repo_evidence])
    end

    get repositories_api_v1_package_url(@package)

    assert_response :success
    assert_equal [@project.id, @runtime.id], response.parsed_body.pluck("id")
  end

  test "omits hidden projects on both paths" do
    owner = Owner.create!(host: Host.create!(name: "HF test host"), login: "hidden", hidden: true)
    [@project, @runtime].each { |project| project.update_columns(owner_id: owner.id) }

    get repositories_api_v1_package_url(@package)

    assert_response :success
    assert_empty response.parsed_body
    assert_equal "0", response.headers.fetch("total-count")
  end

  test "paginates repositories with their complete evidence" do
    get repositories_api_v1_package_url(@package), params: { per_page: 1 }
    assert_response :success
    assert_equal [@project.id], response.parsed_body.pluck("id")
    assert_equal "2", response.headers.fetch("total-count")
    get repositories_api_v1_package_url(@package), params: { per_page: 1, page: 2 }
    assert_response :success
    assert_equal [@runtime.id], response.parsed_body.pluck("id")
    assert_equal "supported_runtime", response.parsed_body.sole.fetch("relationships").sole.fetch("role")
    get repositories_api_v1_package_url(@package), params: { per_page: 1000 }
    assert_response :success
    assert_equal "100", response.headers.fetch("page-items")
  end

  test "distinguishes an unknown package from a package without reviewed links" do
    get repositories_api_v1_package_url(id: Package.maximum(:id) + 1)
    assert_response :not_found
    @package.package_projects.delete_all
    @package.package_papers.delete_all
    get repositories_api_v1_package_url(@package)
    assert_response :success
    assert_empty response.parsed_body
  end

  test "bulk purl lookup advertises the read-only repository endpoint for an unranked model" do
    post bulk_lookup_api_v1_packages_url, params: { purls: [@package.purl] }, as: :json
    assert_response :success
    assert_equal repositories_api_v1_package_url(@package), response.parsed_body.sole.fetch("repositories_url")
  end
end
