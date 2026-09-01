require "test_helper"

class AuthorIdentifierTest < ActiveSupport::TestCase
  test "returns public URLs only for identifiers marked for display" do
    author = Author.create!(canonical_key: "orcid:0000-0002-1825-0097")
    orcid = AuthorIdentifier.create!(
      author: author,
      scheme: "orcid",
      value: "0000-0002-1825-0097",
      publicly_visible: true
    )
    openalex = AuthorIdentifier.create!(
      author: author,
      scheme: "openalex",
      value: "A123",
      publicly_visible: true
    )
    email = AuthorIdentifier.create!(
      author: author,
      scheme: "email",
      value: "private@example.edu",
      publicly_visible: true
    )

    assert_equal "https://orcid.org/0000-0002-1825-0097", orcid.public_url
    assert_equal "https://openalex.org/A123", openalex.public_url
    assert_nil email.public_url
    assert_equal [openalex, orcid], author.public_identifiers.reload.to_a
  end
end
