require "test_helper"
require "rake"

class AwesomeListsRakeTest < ActiveSupport::TestCase
  FIRST_LIST = "nschloe/awesome-scientific-computing"
  SECOND_LIST = "jonathansick/awesome-astronomy"

  setup do
    @env = ENV.to_h.slice("LISTS", "MAX_PAGES")
    %w[LISTS MAX_PAGES].each { |key| ENV.delete(key) }
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:import_awesome_lists")
    Rake::Task["projects:import_awesome_lists"].reenable
    Project::Importers::AWESOME_LISTS.each { |slug| stub_list(slug, []) }
  end

  teardown do
    %w[LISTS MAX_PAGES].each { |key| ENV.delete(key) }
    ENV.update(@env)
  end

  test "scheduled importer paginates curated lists and deduplicates repository candidates" do
    first = { "id" => 45336, "url" => "https://github.com/Research/Model", "repository" => {
      "html_url" => "https://github.com/Research/Model.git", "language" => "Python", "topics" => []
    } }
    stub_list(FIRST_LIST, [first], next_page: 2)
    stub_list(FIRST_LIST, [candidate("https://github.com/research/second")], page: 2)
    stub_list(SECOND_LIST, [candidate("https://github.com/research/model")])
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .select { |entry| entry.fetch("command").include?("projects:import_awesome_lists") }.sole
    assert_equal "0 2 * * 0", cron.fetch("schedule")

    stats = nil
    assert_difference("Project.count", 2) do
      assert_no_difference("ExternalSoftwareRecord.count") do
        output, = capture_io { Rake::Task[cron.fetch("command").split.last].invoke }
        stats = JSON.parse(output)
      end
    end

    assert_equal({ "created" => 2, "sync_requested" => 2, "failed_lists" => 0, "truncated_lists" => 0 }, stats)
    projects = Project.where(url: %w[https://github.com/research/model https://github.com/research/second])
    assert projects.all? { |project| project.science_score.to_f.zero? }
    assert_equal projects.pluck(:id).sort, ExternalProjectSync.where(project_id: projects.select(:id)).pluck(:project_id).sort
    assert_requested :get, list_url(FIRST_LIST, 2), times: 1
  end

  test "existing projects and aliases share one sync request which repeated imports preserve" do
    zero = Project.create!(url: "https://github.com/research/current", science_score: 0)
    ProjectRepositoryAlias.create!(project: zero, url: "https://github.com/research/former")
    scientific = Project.create!(url: "https://github.com/research/scientific", science_score: 40)
    stub_list(FIRST_LIST, [candidate(zero.url), candidate("https://github.com/research/former"), candidate(scientific.url)])

    assert_no_difference("Project.count") { run_import }
    request = ExternalProjectSync.find_by!(project_id: zero.id)
    request.update!(completed_at: request.requested_at)
    before = request.attributes
    assert_no_difference("ExternalProjectSync.count") do
      stats = run_import
      assert_equal 0, stats.fetch("sync_requested")
    end

    assert_equal before, request.reload.attributes
    assert_not ExternalProjectSync.exists?(project_id: scientific.id)
    assert_equal 0, zero.reload.science_score
    assert_equal 40, scientific.reload.science_score
  end

  test "ambiguous aliases and hidden owners cannot create projects or request sync" do
    first = Project.create!(url: "https://github.com/research/first")
    second = Project.create!(url: "https://github.com/research/second")
    [first, second].each { |project| ProjectRepositoryAlias.create!(project: project, url: "https://github.com/research/shared") }
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "hidden", hidden: true)
    hidden = Project.new(url: "https://github.com/hidden/existing", owner_record: owner)
    hidden.save!(validate: false)
    ProjectRepositoryAlias.create!(project: hidden, url: "https://github.com/research/hidden-alias")
    stub_list(FIRST_LIST, %w[
      https://github.com/research/shared
      https://github.com/hidden/new
      https://github.com/research/hidden-alias
    ].map { |url| candidate(url) })

    assert_no_difference("Project.count") do
      assert_no_difference("ExternalProjectSync.count") { run_import }
    end
  end

  test "known GitLab forges preserve nested groups and exclude hidden parent namespaces" do
    host = Host.create!(name: "gitlab.example.edu", kind: "GitLab", url: "https://gitlab.example.edu")
    Owner.create!(host: host, login: "hidden/subgroup", hidden: true)
    stub_list(FIRST_LIST, [
      candidate("https://gitlab.example.edu/lab/team/model/-/tree/main"),
      candidate("https://gitlab.example.edu/hidden/subgroup/team/model")
    ])

    assert_difference("Project.count", 1) { run_import }
    project = Project.find_by!(url: "https://gitlab.example.edu/lab/team/model")
    assert ExternalProjectSync.exists?(project_id: project.id)
    assert_not Project.exists?(url: "https://gitlab.example.edu/hidden/subgroup/team/model")
  end

  test "unresolved invalid unsupported and source-list entries are skipped" do
    stub_list(FIRST_LIST, [
      { "id" => 1, "url" => "https://github.com/research/unresolved", "repository" => nil },
      candidate("https://github.com/#{FIRST_LIST}"),
      candidate("https://bitbucket.org/research/model"),
      candidate("https://unknown.example.org/research/model"),
      candidate("https://github.com:444/research/model"),
      candidate("https://user:secret@github.com/research/model"),
      candidate("not a URL"),
      candidate(nil),
      nil
    ])

    assert_no_difference("Project.count") do
      assert_no_difference("ExternalProjectSync.count") { run_import }
    end
  end

  test "failed list pages leave other lists eligible and report an unsuccessful task" do
    stub_request(:get, list_url(FIRST_LIST)).to_return(status: 503)
    stub_list(SECOND_LIST, [candidate("https://github.com/research/survivor")])
    output, error = capture_io do
      failure = assert_raises(SystemExit) { Rake::Task["projects:import_awesome_lists"].invoke }
      assert_equal 1, failure.status
    end

    assert_equal 1, JSON.parse(output).fetch("failed_lists")
    assert_includes error, "HTTP 503"
    assert_includes error, "Awesome list import incomplete"
    assert Project.exists?(url: "https://github.com/research/survivor")
    assert ExternalProjectSync.exists?(project_id: Project.find_by!(url: "https://github.com/research/survivor").id)
  end

  test "invalid page data and timeouts are reported without importing unverified entries" do
    stub_request(:get, list_url(FIRST_LIST)).to_return(body: { "error" => "invalid page" }.to_json)
    stub_request(:get, list_url(SECOND_LIST)).to_timeout

    output = nil
    assert_no_difference("Project.count") do
      output, = capture_io { assert_raises(SystemExit) { Rake::Task["projects:import_awesome_lists"].invoke } }
    end
    assert_equal 2, JSON.parse(output).fetch("failed_lists")
  end

  test "page limits are reported and arbitrary source lists are rejected" do
    stub_list(FIRST_LIST, [candidate("https://github.com/research/bounded")], next_page: 2)
    ENV["LISTS"] = FIRST_LIST
    ENV["MAX_PAGES"] = "1"

    output, = capture_io { assert_raises(SystemExit) { Rake::Task["projects:import_awesome_lists"].invoke } }

    assert_equal 1, JSON.parse(output).fetch("truncated_lists")
    assert_requested :get, list_url(FIRST_LIST), times: 1
    assert_not_requested :get, list_url(FIRST_LIST, 2)
    assert_raises(ArgumentError) { Project.import_from_awesome_lists(lists: ["unreviewed/list"]) }
    assert_raises(ArgumentError) { Project.import_from_awesome_lists(max_pages: 0) }
    assert_raises(ArgumentError) { Project.import_from_awesome_lists(max_pages: 101) }
  end

  def candidate(url)
    { "url" => url, "repository" => { "html_url" => url } }
  end

  def list_url(slug, page = 1)
    "https://awesome.ecosyste.ms/api/v1/lists/#{slug}/projects?with_repository=true&not_list=true&per_page=100&page=#{page}"
  end

  def stub_list(slug, entries, page: 1, next_page: nil)
    headers = next_page ? { "Link" => "<#{list_url(slug, next_page)}>; rel=\"next\"" } : {}
    stub_request(:get, list_url(slug, page)).with(headers: { "User-Agent" => "science.ecosyste.ms" })
      .to_return(body: entries.to_json, headers: headers)
  end

  def run_import
    Rake::Task["projects:import_awesome_lists"].reenable
    output, = capture_io { Rake::Task["projects:import_awesome_lists"].invoke }
    JSON.parse(output)
  end
end
