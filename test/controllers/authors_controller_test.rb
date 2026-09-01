require "test_helper"

class AuthorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = Host.create!(name: "GitHub", url: "https://github.com")
  end

  test "index lists canonical authors alphabetically with public role counts" do
    zed = create_author("orcid:0000-0001-5109-3700", "Zed Researcher")
    ada = create_author("orcid:0000-0002-1825-0097", "Ada Lovelace")
    software = create_project("software", "Software Project")
    preferred = create_project("preferred", "Preferred Project")
    contributed = create_project("contributed", "Contributed Project")
    create_project_author(ada, software, "software")
    create_project_author(ada, preferred, "preferred_citation")
    create_project_author(zed, software, "software", position: 2)
    create_project_contributor(ada, contributed, "ada", contributions_count: 7)
    unnamed = create_author("email:unnamed-private@example.edu", nil)
    unnamed_project = create_project("unnamed", "Unnamed Project")
    create_project_author(unnamed, unnamed_project, "software")
    AuthorIdentifier.create!(
      author: ada,
      scheme: "orcid",
      value: "0000-0002-1825-0097",
      publicly_visible: true
    )
    AuthorIdentifier.create!(
      author: ada,
      scheme: "email",
      value: "ada-private@example.edu",
      publicly_visible: false
    )
    hidden_author = create_author("email:hidden@example.edu", "Hidden Author")
    hidden_owner = Owner.create!(
      host: @host,
      login: "hidden-owner"
    )
    hidden_project = create_project(
      "hidden",
      "Hidden Project",
      owner: hidden_owner
    )
    create_project_author(hidden_author, hidden_project, "software")
    hidden_owner.update_column(:hidden, true)
    unscientific_author = create_author(
      "email:unscientific@example.edu",
      "Unscientific Author"
    )
    unscientific_project = create_project(
      "unscientific",
      "Unscientific Project",
      science_score: Project::SCIENCE_SCORE_THRESHOLD - 1
    )
    create_project_author(unscientific_author, unscientific_project, "software")

    get authors_url

    assert_response :success
    assert_select "h1", text: "Authors"
    assert_select "a[href='#{authors_path}']", text: "Authors"
    assert_select "[data-author-id]" do |authors|
      assert_equal [ada.id, unnamed.id, zed.id],
        authors.map { |element| element["data-author-id"].to_i }
    end
    assert_select "[data-author-id='#{ada.id}']" do
      assert_select "a[href='#{author_path(ada)}']", text: ada.display_name
      assert_select "a[href='https://orcid.org/0000-0002-1825-0097']",
        text: "ORCID 0000-0002-1825-0097"
      assert_select "div", text: /1 software project/
      assert_select "div", text: /1 preferred citation/
      assert_select "div", text: /1 contributed project/
    end
    assert_no_match "ada-private@example.edu", response.body
    assert_select "[data-author-id='#{unnamed.id}'] a[href='#{author_path(unnamed)}']",
      text: "Unnamed author"
    assert_no_match "unnamed-private@example.edu", response.body
    assert_no_match hidden_author.display_name, response.body
    assert_no_match hidden_project.name, response.body
    assert_no_match unscientific_author.display_name, response.body
    assert_no_match unscientific_project.name, response.body
  end

  test "show keeps authorship and contribution roles separate without private identity data" do
    author = create_author("orcid:0000-0002-1825-0097", "Ada Lovelace")
    other_author = create_author("orcid:0000-0001-5109-3700", "Grace Hopper")
    software = create_project("software", "Software Project")
    preferred = create_project("preferred", "Preferred Project")
    contributed = create_project("contributed", "Contributed Project")
    create_project_author(author, software, "software")
    create_project_author(author, preferred, "preferred_citation")
    create_project_contributor(author, contributed, "ada-one", contributions_count: 3)
    create_project_contributor(author, contributed, "ada-two", contributions_count: 4)
    AuthorIdentifier.create!(
      author: author,
      scheme: "orcid",
      value: "0000-0002-1825-0097",
      publicly_visible: true
    )
    AuthorIdentifier.create!(
      author: author,
      scheme: "email",
      value: "private-author@example.edu",
      publicly_visible: true
    )

    visible_account = create_account("ada", name: "Ada Account")
    visible_account.update!(email: "private-account@example.edu")
    create_account_link(author, visible_account, "visible")
    user_owner = Owner.create!(
      host: @host,
      login: "ada-owner",
      kind: "user"
    )
    owner_account = create_account("ada-owner", owner: user_owner)
    create_account_link(author, owner_account, "owner")
    bot_account = create_account("dependabot[bot]", account_kind: "bot")
    create_account_link(author, bot_account, "bot")
    organization = Owner.create!(
      host: @host,
      login: "research-org",
      kind: "organization"
    )
    organization_account = create_account("research-org", owner: organization)
    create_account_link(author, organization_account, "organization")
    hidden_owner = Owner.create!(
      host: @host,
      login: "hidden-user",
      kind: "user",
      hidden: true
    )
    hidden_account = create_account("hidden-user", owner: hidden_owner)
    create_account_link(author, hidden_account, "hidden")
    ambiguous_account = create_account("shared-account")
    create_account_link(author, ambiguous_account, "ambiguous-one")
    create_account_link(
      other_author,
      ambiguous_account,
      "ambiguous-two",
      deterministic: false
    )

    get author_url(author)

    assert_response :success
    assert_select "h1", text: author.display_name
    assert_select "a[href='https://orcid.org/0000-0002-1825-0097']",
      text: "ORCID 0000-0002-1825-0097"
    assert_select "[data-developer-account-id='#{visible_account.id}']" do
      assert_select "a[href='https://github.com/ada']", text: "ada"
      assert_select "a[href='#{host_path(@host.name)}']", text: @host.name
    end
    assert_select "[data-developer-account-id='#{owner_account.id}']" do
      assert_select "a[href='#{host_owner_path(@host.name, user_owner.login)}']",
        text: user_owner.login
    end
    assert_select "[data-developer-account-id='#{bot_account.id}']", count: 0
    assert_select "[data-developer-account-id='#{organization_account.id}']", count: 0
    assert_select "[data-developer-account-id='#{hidden_account.id}']", count: 0
    assert_select "[data-developer-account-id='#{ambiguous_account.id}']", count: 0
    assert_select "[data-role='software-authorship']" do
      assert_select "[data-project-id='#{software.id}']", count: 1
      assert_select "[data-project-id='#{preferred.id}']", count: 0
      assert_select "[data-project-id='#{contributed.id}']", count: 0
    end
    assert_select "[data-role='preferred-citations']" do
      assert_select "[data-project-id='#{software.id}']", count: 0
      assert_select "[data-project-id='#{preferred.id}']", count: 1
      assert_select "[data-project-id='#{contributed.id}']", count: 0
    end
    assert_select "[data-role='repository-contributions']" do
      assert_select "[data-project-id='#{software.id}']", count: 0
      assert_select "[data-project-id='#{preferred.id}']", count: 0
      assert_select "[data-project-id='#{contributed.id}']" do
        assert_select "div", text: /7 contributions/
      end
    end
    assert_no_match "private-author@example.edu", response.body
    assert_no_match "private-account@example.edu", response.body
    assert_no_match "email_sha256", response.body
  end

  test "show returns not found when an author has no visible scientific evidence" do
    author = create_author("email:hidden@example.edu", "Hidden Author")
    owner = Owner.create!(host: @host, login: "hidden")
    project = create_project("hidden", "Hidden Project", owner: owner)
    create_project_author(author, project, "software")
    owner.update_column(:hidden, true)

    get author_url(author)

    assert_response :not_found
  end

  test "show paginates software projects independently" do
    author = create_author("email:many@example.edu", "Many Projects")
    projects = 21.times.map do |index|
      project = create_project(
        "software-#{index}",
        "Project #{index}",
        science_score: 100 - index
      )
      create_project_author(author, project, "software")
      project
    end

    get author_url(author), params: { software_page: 2 }

    assert_response :success
    assert_select "[data-role='software-authorship'] [data-project-id]", count: 1
    assert_select "[data-role='software-authorship'] [data-project-id='#{projects.last.id}']",
      count: 1
  end

  test "index and show keep paper authorship and editorial roles separate" do
    author = create_author("orcid:0000-0002-1825-0097", "Ada Lovelace")
    project = create_project("papers", "Paper Project")
    authored = Paper.create!(
      doi: "10.21105/joss.12345",
      title: "Authored Paper",
      publication_date: Time.zone.parse("2026-08-30")
    )
    edited = Paper.create!(
      doi: "10.21105/joss.54321",
      title: "Edited Paper"
    )
    Mention.create!(project: project, paper: authored)
    Mention.create!(project: project, paper: edited)
    create_paper_author(author, authored, "author")
    create_paper_author(author, edited, "editor")

    get authors_url

    assert_response :success
    assert_select "[data-author-id='#{author.id}']" do
      assert_select "div", text: /1 authored paper/
      assert_select "div", text: /1 edited paper/
    end

    get author_url(author)

    assert_response :success
    assert_select "[data-role='paper-authorship']" do
      assert_select "[data-paper-id='#{authored.id}']" do
        assert_select "h3", text: authored.title
        assert_select "a[href='https://doi.org/#{authored.doi}']",
          text: authored.doi
        assert_select "time[datetime='2026-08-30']"
      end
      assert_select "[data-paper-id='#{edited.id}']", count: 0
    end
    assert_select "[data-role='paper-editing']" do
      assert_select "[data-paper-id='#{authored.id}']", count: 0
      assert_select "[data-paper-id='#{edited.id}']", count: 1
    end
  end

  test "paper evidence from a hidden project is not public" do
    author = create_author("orcid:0000-0002-1825-0097", "Hidden Paper Author")
    owner = Owner.create!(host: @host, login: "hidden-paper-owner")
    project = create_project("hidden-paper", "Hidden Paper", owner: owner)
    paper = Paper.create!(doi: "10.21105/joss.99999", title: "Hidden Paper")
    Mention.create!(project: project, paper: paper)
    create_paper_author(author, paper, "author")
    owner.update_column(:hidden, true)

    get author_url(author)

    assert_response :not_found
  end

  def create_author(canonical_key, display_name)
    Author.create!(canonical_key: canonical_key, display_name: display_name)
  end

  def create_project(key, name, owner: nil, science_score: 60)
    Project.create!(
      url: "https://github.com/test/#{key}",
      name: name,
      science_score: science_score,
      owner_record: owner
    )
  end

  def create_project_author(author, project, authorship_kind, position: 1)
    ProjectAuthor.create!(
      project: project,
      author: author,
      source: "citation_cff",
      authorship_kind: authorship_kind,
      author_kind: "person",
      position: position,
      display_name: author.display_name,
      source_path: "authors[#{position - 1}]",
      source_digest: "author-#{project.id}-#{authorship_kind}-#{position}"
    )
  end

  def create_project_contributor(author, project, source_key, contributions_count: 1)
    ProjectContributor.create!(
      project: project,
      author: author,
      source: "commits_ecosyste_ms",
      source_key: source_key,
      name: author.display_name,
      account_kind: "unknown",
      contributions_count: contributions_count,
      source_digest: "contributor-#{project.id}-#{source_key}"
    )
  end

  def create_paper_author(author, paper, role)
    PaperAuthor.create!(
      paper: paper,
      author: author,
      source: "joss",
      role: role,
      position: 1,
      display_name: author.display_name,
      orcid: author.canonical_key.delete_prefix("orcid:"),
      source_path: role == "author" ? "authors[0]" : "editor",
      source_digest: "paper-author-#{paper.id}-#{role}"
    )
  end

  def create_account(login, name: nil, account_kind: "unknown", owner: nil)
    DeveloperAccount.create!(
      host: @host,
      owner: owner,
      canonical_key: "login:#{@host.id}:#{login}",
      login: login,
      name: name,
      account_kind: account_kind
    )
  end

  def create_account_link(author, account, key, deterministic: true)
    AuthorDeveloperAccountLink.create!(
      author: author,
      developer_account: account,
      source: "same_project_email",
      source_key: key,
      matching_method: "exact_email",
      deterministic: deterministic,
      source_digest: "digest-#{key}",
      evidence: { "email_sha256" => "private-digest-#{key}" }
    )
  end
end
