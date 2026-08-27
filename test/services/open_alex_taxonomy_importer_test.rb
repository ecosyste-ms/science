require "test_helper"

class OpenAlexTaxonomyImporterTest < ActiveSupport::TestCase
  test "imports the official hierarchy and deactivates missing topics" do
    stale = create_topic("https://openalex.org/T-old", active: true)
    client = mock
    client.stubs(:each_topic_page).multiple_yields(
      [[topic_data("https://openalex.org/T1")]],
      [[topic_data("https://openalex.org/T2")]]
    )

    result = OpenAlexTaxonomyImporter.sync!(
      client: client,
      minimum_topics: 2
    )

    assert_equal 2, result[:topics]
    assert_equal 2, result[:created]
    assert_equal 1, result[:deactivated]
    assert_not stale.reload.active?

    topic = OpenAlexTopic.find_by!(openalex_id: "https://openalex.org/T1")
    assert_equal "Software", topic.subfield_name
    assert_equal "Computer Science", topic.field_name
    assert_equal "Physical Sciences", topic.domain_name
    assert_equal ["research software", "source code"], topic.keywords
  end

  test "does not alter data when the response is unexpectedly small" do
    existing = create_topic("https://openalex.org/T-existing", active: true)
    client = mock
    client.stubs(:each_topic_page).yields([topic_data("https://openalex.org/T1")])

    assert_raises(RuntimeError) do
      OpenAlexTaxonomyImporter.sync!(client: client, minimum_topics: 2)
    end

    assert existing.reload.active?
    assert_not OpenAlexTopic.exists?(openalex_id: "https://openalex.org/T1")
  end

  def create_topic(openalex_id, active: true)
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: "Existing",
      subfield_id: "1",
      subfield_name: "Subfield",
      field_id: "2",
      field_name: "Field",
      domain_id: "3",
      domain_name: "Domain",
      active: active
    )
  end

  def topic_data(openalex_id)
    {
      "id" => openalex_id,
      "display_name" => "Research Software",
      "description" => "Software used in research",
      "keywords" => ["research software", "source code"],
      "subfield" => { "id" => 1712, "display_name" => "Software" },
      "field" => { "id" => 17, "display_name" => "Computer Science" },
      "domain" => { "id" => 3, "display_name" => "Physical Sciences" },
      "updated_date" => "2026-08-01",
    }
  end
end
