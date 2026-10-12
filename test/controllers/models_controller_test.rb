require "test_helper"

class ModelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co",
      ecosystem: "huggingface", purl_type: "huggingface")
    @bert = create_model("Google/BERT", keywords: ["Text-Classification"], science_score: 0, last_synced_at: 1.hour.ago)
    @specter = create_model("AllenAI/SPECTER", keywords: ["embeddings"], science_score: 60, last_synced_at: 2.hours.ago)
    @unscanned = create_model("Example/Unscanned")
  end

  test "lists model publishers including unscanned and zero score projects" do
    implementation = Project.create!(url: "https://github.com/example/implementation", science_score: 80)
    package = @registry.packages.find_by!(published_by_project: @bert)
    PackageProject.create!(package: package, project: implementation, role: "model_implementation",
      evidence: [{ "source" => "review", "url" => implementation.url }])
    hidden = create_model("Example/Hidden")
    owner = Owner.create!(host: hidden.host, login: "hidden")
    hidden.update!(owner_record: owner)
    owner.update!(hidden: true)

    get models_url

    assert_response :success
    assert_select "h1", text: "Models"
    assert_select "h2", text: "3 models"
    assert_project_order [@bert, @specter, @unscanned]
    assert_select "#project_#{@bert.id} h3 a[href='#{project_path(@bert)}']"
    assert_select "#project_#{implementation.id}", count: 0
    assert_select "#project_#{hidden.id}", count: 0
  end

  test "combines case insensitive search keyword and owner filters" do
    get models_url, params: { q: "bert", keyword: "text-classification", owner: "GOOGLE" }

    assert_response :success
    assert_project_order [@bert]
    assert_select "input[name='q'][value='bert']"
    assert_select "input[name='keyword'][value='text-classification']"
    assert_select "input[name='owner'][value='GOOGLE']"
    assert_select "#project_#{@bert.id} a", text: "Text-Classification" do |links|
      uri = URI.parse(links.sole["href"])
      assert_equal models_path, uri.path
      assert_equal "GOOGLE", Rack::Utils.parse_query(uri.query)["owner"]
    end

    get models_url, params: { owner: "allenai" }
    assert_project_order [@specter]
    get models_url, params: { keyword: "EMBEDDINGS" }
    assert_project_order [@specter]
  end

  test "searches names and treats wildcard characters literally" do
    @bert.update!(name: "100%_BERT")
    get models_url, params: { q: "100%_bert" }
    assert_project_order [@bert]

    get models_url, params: { q: "%missing" }
    assert_response :success
    assert_select ".listing", count: 0
    assert_select "[role='status']", text: "No models found."
  end

  test "uses card names ahead of cleaned README headings" do
    package = @registry.packages.find_by!(published_by_project: @bert)
    package.update!(metadata: package.metadata.merge("metadata" => { "card_data" => { "model_name" => "BERT classifier" } }))
    ModelProjectSync.link!(package)
    @bert.reload.update!(readme: "# Model card for BERT fallback")
    @specter.update!(readme: "# Model card for SPECTER")

    get models_url

    assert_response :success
    assert_select "#project_#{@bert.id} h3 a", text: /\ABERT classifier/
    assert_select "#project_#{@specter.id} h3 a", text: /\ASPECTER/
    assert_no_match "Model card for", response.body
    assert_no_match "BERT fallback", response.body
  end

  test "does not list model-marked publishers from another registry or repeat shared publishers" do
    other_registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    unrelated = Project.create!(url: "https://github.com/example/other", repository: { "metadata" => { "model_package_purl" => "pkg:pypi/other" } })
    other_registry.packages.create!(name: "other", purl: "pkg:pypi/other", published_by_project: unrelated)
    @registry.packages.create!(name: "Google/BERT-alias", purl: "pkg:huggingface/Google/BERT-alias", published_by_project: @bert)

    get models_url

    assert_response :success
    assert_project_order [@bert, @specter, @unscanned]
    assert_select "h2", text: "3 models"
  end

  test "sorts by science score or name and falls back for unknown sorts" do
    get models_url, params: { sort: "science_score" }
    assert_project_order [@specter, @bert, @unscanned]
    get models_url, params: { sort: "name" }
    assert_project_order [@specter, @unscanned, @bert]
    get models_url, params: { sort: "unknown" }
    assert_project_order [@bert, @specter, @unscanned]
    assert_select "option[value='recently_synced'][selected]"
  end

  test "paginates while retaining filters" do
    21.times { |i| create_model("Page/Model#{i}", last_synced_at: i.minutes.ago) }

    get models_url, params: { owner: "page", sort: "name" }
    assert_response :success
    assert_select ".listing", count: 20
    assert_select "h2", text: "21 models"
    assert_select ".pagination a[href]" do |links|
      next_page = links.find { |link| Rack::Utils.parse_query(URI.parse(link["href"]).query)["page"] == "2" }
      assert next_page
      get next_page["href"]
    end
    assert_response :success
    assert_select ".listing", count: 1
    assert_select "input[name='owner'][value='page']"
    assert_select "option[value='name'][selected]"
  end

  def create_model(name, keywords: [], **attributes)
    package = @registry.packages.create!(name: name, purl: "pkg:huggingface/#{name}", metadata: { "keywords" => keywords })
    project = ModelProjectSync.link!(package)
    project.update!(attributes) if attributes.any?
    project
  end

  def assert_project_order(projects)
    assert_select ".listing" do |elements|
      assert_equal projects.map { |project| "project_#{project.id}" }, elements.map { |element| element["id"] }
    end
  end
end
