require "test_helper"

class AuthorIdentityIndexerTest < ActiveSupport::TestCase
  test "links CFF authors, developer accounts, and exact same-project email evidence" do
    host = Host.create!(name: "Identity GitHub")
    owner = Owner.create!(host: host, login: "adal", uuid: "42")
    project = create_indexed_project(
      host: host,
      citation_file: cff_author(
        name: "Ada Lovelace",
        email: "ada@example.edu",
        orcid: "0000-0002-1825-0097"
      ),
      committers: [
        {
          "name" => "Ada Lovelace",
          "email" => "ada@example.edu",
          "login" => "adal",
          "uuid" => "42",
          "count" => 7,
        },
      ]
    )

    result = AuthorIdentityIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 1, result.fetch(:linked_author_observations)
    assert_equal 1, result.fetch(:linked_account_observations)
    assert_equal 1, result.fetch(:linked_contributors)
    assert_equal 1, result.fetch(:account_author_links)
    author = Author.find_by!(canonical_key: "orcid:0000-0002-1825-0097")
    assert_equal "Ada Lovelace", author.display_name
    assert_equal false,
      author.identifiers.find_by!(scheme: "email").publicly_visible
    assert_equal true,
      author.identifiers.find_by!(scheme: "orcid").publicly_visible
    account = DeveloperAccount.find_by!(owner: owner)
    assert_equal "adal", account.login
    assert_equal author, project.project_authors.first.author
    contributor = project.project_contributors.first
    assert_equal author, contributor.author
    assert_equal account, contributor.developer_account
    link = AuthorDeveloperAccountLink.find_by!(project: project)
    assert_equal "exact_email", link.matching_method
    assert_equal Digest::SHA256.hexdigest("ada@example.edu"),
      link.evidence.fetch("email_sha256")
    assert_not link.evidence.key?("email")
    assert project.reload.author_identities_indexed_at.present?
    assert_equal 2, author.reload.public_evidence_count
  end

  test "uses the sole global ORCID for an email-only CFF author" do
    identified = create_indexed_project(
      citation_file: cff_author(
        name: "Identified Author",
        email: "shared@example.edu",
        orcid: "0000-0002-1825-0097"
      )
    )
    email_only = create_indexed_project(
      citation_file: cff_author(
        name: "Same Author",
        email: "shared@example.edu"
      )
    )

    result = AuthorIdentityIndexer.new(email_only).sync!

    assert result.fetch(:indexed)
    author = email_only.project_authors.first.author
    assert_equal "0000-0002-1825-0097",
      author.identifiers.find_by!(scheme: "orcid").value
    assert_equal "email_to_orcid",
      email_only.project_authors.first.author_match_kind

    AuthorIdentityIndexer.new(identified).sync!

    assert_equal identified.project_authors.first.author, author
    assert_equal 1, Author.count
  end

  test "leaves email-only authors unlinked when the email has conflicting ORCIDs" do
    create_indexed_project(
      citation_file: cff_author(
        name: "First Author",
        email: "shared@example.edu",
        orcid: "0000-0002-1825-0097"
      )
    )
    create_indexed_project(
      citation_file: cff_author(
        name: "Second Author",
        email: "shared@example.edu",
        orcid: "0000-0001-5109-3700"
      )
    )
    target = create_indexed_project(
      citation_file: cff_author(
        name: "Ambiguous Author",
        email: "shared@example.edu"
      )
    )

    result = AuthorIdentityIndexer.new(target).sync!

    assert_equal 1, result.fetch(:ambiguous)
    assert_nil target.project_authors.first.reload.author_id
    assert_equal 0, Author.count
  end

  test "creates bot developer accounts without linking them to authors" do
    host = Host.create!(name: "Bot GitHub")
    project = create_indexed_project(
      host: host,
      citation_file: cff_author(
        name: "Automation Account",
        email: "49699333+dependabot[bot]@users.noreply.github.com"
      ),
      committers: [
        {
          "name" => "dependabot",
          "email" => "49699333+dependabot[bot]@users.noreply.github.com",
          "count" => 2,
        },
      ]
    )

    AuthorIdentityIndexer.new(project).sync!

    contributor = project.project_contributors.first
    assert_equal "bot", contributor.developer_account.account_kind
    assert_nil contributor.author_id
    assert_equal 0, Author.count
    assert_empty AuthorDeveloperAccountLink.where(project: project)
  end

  test "coalesces provider and login observations into one developer account" do
    host = Host.create!(name: "Coalesce GitHub")
    project = create_indexed_project(
      host: host,
      committers: [
        { "name" => "Ada", "login" => "adal", "uuid" => "42", "count" => 2 },
        { "name" => "Ada", "login" => "adal", "count" => 3 },
      ]
    )

    result = AuthorIdentityIndexer.new(project).sync!

    assert_equal 2, result.fetch(:linked_account_observations)
    assert_equal 1, DeveloperAccount.count
    assert_equal 2, DeveloperAccountIdentifier.count
    assert_equal 1,
      project.project_contributors.reload.pluck(:developer_account_id).uniq.length
  end

  test "leaves a shared login unresolved when provider identifiers conflict" do
    host = Host.create!(name: "Conflicting Provider GitHub")
    project = create_indexed_project(
      host: host,
      committers: [
        {
          "name" => "First",
          "login" => "shared",
          "uuid" => "42",
          "count" => 2,
        },
        {
          "name" => "Second",
          "login" => "shared",
          "uuid" => "84",
          "count" => 3,
        },
      ]
    )

    result = AuthorIdentityIndexer.new(project).sync!

    assert_equal 0, result.fetch(:linked_account_observations)
    assert_equal 2, result.fetch(:ambiguous)
    assert_empty project.project_contributors.reload.where.not(
      developer_account_id: nil
    )
    assert_equal 0, DeveloperAccount.count
    assert_equal 0, DeveloperAccountIdentifier.count
  end

  test "does not reuse an account with conflicting provider identifiers" do
    host = Host.create!(name: "Existing Conflict GitHub")
    account = DeveloperAccount.create!(
      host: host,
      canonical_key: "host:#{host.id}:provider:42",
      provider_uuid: "42",
      login: "shared",
      account_kind: "unknown"
    )
    %w[42 84].each do |provider_uuid|
      DeveloperAccountIdentifier.create!(
        developer_account: account,
        host: host,
        scheme: "provider",
        value: provider_uuid
      )
    end
    DeveloperAccountIdentifier.create!(
      developer_account: account,
      host: host,
      scheme: "login",
      value: "shared"
    )
    project = create_indexed_project(
      host: host,
      committers: [
        {
          "name" => "First",
          "login" => "shared",
          "uuid" => "42",
          "count" => 2,
        },
      ]
    )

    result = AuthorIdentityIndexer.new(project).sync!

    assert_equal 0, result.fetch(:linked_account_observations)
    assert_equal 1, result.fetch(:ambiguous)
    assert_nil project.project_contributors.first.reload.developer_account_id
  end

  test "does not link an author through an account with bot evidence" do
    host = Host.create!(name: "Mixed Bot GitHub")
    project = create_indexed_project(
      host: host,
      citation_file: cff_author(
        name: "Ada Lovelace",
        email: "ada@example.edu"
      ),
      committers: [
        {
          "name" => "Automation",
          "email" => "49699333+automation[bot]@users.noreply.github.com",
          "login" => "shared-login",
          "uuid" => "42",
          "count" => 2,
        },
        {
          "name" => "Ada Lovelace",
          "email" => "ada@example.edu",
          "login" => "shared-login",
          "count" => 2,
        },
      ]
    )

    AuthorIdentityIndexer.new(project).sync!

    contributor = project.project_contributors.find_by!(email: "ada@example.edu")
    assert_equal "bot", contributor.developer_account.account_kind
    assert_nil contributor.author_id
    assert_empty AuthorDeveloperAccountLink.where(project: project)
  end

  test "does not link an author through an organization owner account" do
    host = Host.create!(name: "Organization GitHub")
    owner = Owner.create!(
      host: host,
      login: "research-group",
      uuid: "84",
      kind: "organization"
    )
    project = create_indexed_project(
      host: host,
      citation_file: cff_author(
        name: "Ada Lovelace",
        email: "ada@example.edu"
      ),
      committers: [
        {
          "name" => "Ada Lovelace",
          "email" => "ada@example.edu",
          "login" => "research-group",
          "uuid" => "84",
          "count" => 2,
        },
      ]
    )

    AuthorIdentityIndexer.new(project).sync!

    contributor = project.project_contributors.first
    assert_equal owner, contributor.developer_account.owner
    assert_nil contributor.author_id
    assert_empty AuthorDeveloperAccountLink.where(project: project)
  end

  test "removes stale account-author evidence after a CFF author email changes" do
    host = Host.create!(name: "Stale GitHub")
    project = create_indexed_project(
      host: host,
      citation_file: cff_author(
        name: "Ada Lovelace",
        email: "ada@example.edu"
      ),
      committers: [
        {
          "name" => "Ada Lovelace",
          "email" => "ada@example.edu",
          "login" => "adal",
          "count" => 2,
        },
      ]
    )
    AuthorIdentityIndexer.new(project).sync!
    project.update!(
      citation_file: cff_author(
        name: "Ada Lovelace",
        email: "different@example.edu"
      )
    )
    ProjectCitationAuthorIndexer.new(project).sync!

    AuthorIdentityIndexer.new(project).sync!

    assert_nil project.project_contributors.first.reload.author_id
    assert_empty AuthorDeveloperAccountLink.where(project: project)
  end

  test "skips an unchanged identity snapshot" do
    project = create_indexed_project(
      citation_file: cff_author(
        name: "Ada Lovelace",
        email: "ada@example.edu"
      )
    )
    AuthorIdentityIndexer.new(project).sync!
    indexed_at = project.reload.author_identities_indexed_at

    travel 1.minute do
      result = AuthorIdentityIndexer.new(project).sync!

      assert_not result.fetch(:indexed)
      assert_equal indexed_at, project.reload.author_identities_indexed_at
    end
  end

  test "processes a bounded batch of scientific projects" do
    first = create_indexed_project(citation_file: cff_author(name: "First"))
    second = create_indexed_project(citation_file: cff_author(name: "Second"))

    result = AuthorIdentityIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:indexed)
    assert_equal 1,
      Project.where(id: [first.id, second.id])
        .where.not(author_identities_indexed_at: nil)
        .count
  end

  test "links a two thousand account snapshot in chunks" do
    host = Host.create!(name: "Large Identity GitHub")
    project = create_indexed_project(
      host: host,
      committers: 2_000.times.map do |index|
        {
          "name" => "Contributor #{index}",
          "login" => "contributor-#{index}",
          "count" => 1,
        }
      end
    )

    result = AuthorIdentityIndexer.new(project).sync!

    assert_equal 2_000, result.fetch(:linked_account_observations)
    assert_equal 2_000, project.project_contributors.reload.where.not(
      developer_account_id: nil
    ).count
    assert_equal 2_000, DeveloperAccount.count
  end

  test "rejects an invalid batch limit" do
    error = assert_raises(ArgumentError) do
      AuthorIdentityIndexer.sync_batch!(limit: 0)
    end

    assert_equal "limit must be between 1 and 1000", error.message
  end

  def create_indexed_project(host: nil, citation_file: nil, committers: [])
    @project_number = @project_number.to_i + 1
    project = Project.create!(
      url: "https://github.com/test/author-identity-#{@project_number}",
      science_score: 20,
      host: host,
      citation_file: citation_file,
      commits: { "committers" => committers }
    )
    ProjectCitationAuthorIndexer.new(project).sync!
    ProjectContributorIndexer.new(project).sync!
    project.reload
  end

  def cff_author(name:, email: nil, orcid: nil)
    given_names, family_names = name.split(" ", 2)
    fields = [
      "    - given-names: #{given_names}",
      "      family-names: #{family_names || 'Author'}",
    ]
    fields << "      email: #{email}" if email
    fields << "      orcid: https://orcid.org/#{orcid}" if orcid
    <<~CFF
      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
      #{fields.join("\n")}
    CFF
  end
end
