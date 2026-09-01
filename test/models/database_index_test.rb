require "test_helper"

class DatabaseIndexTest < ActiveSupport::TestCase
  INDEX_PAIRS = {
    packages: [
      "index_packages_on_package_registry_id",
      "index_packages_on_registry_and_name",
    ],
    project_authors: [
      "index_project_authors_on_project_id",
      "index_project_authors_on_snapshot_position",
    ],
    project_contributors: [
      "index_project_contributors_on_project_id",
      "index_project_contributors_on_source_key",
    ],
    project_fields: [
      "index_project_fields_on_project_id",
      "index_project_fields_on_project_id_and_field_id",
    ],
    project_repository_aliases: [
      "index_project_repository_aliases_on_project_id",
      "index_project_repository_aliases_on_project_and_url",
    ],
  }.freeze

  OPEN_ALEX_TOPIC_INDEX_PAIRS = [
    [
      "index_project_open_alex_topics_on_open_alex_topic_id",
      "index_project_open_alex_topics_on_topic_and_score",
    ],
    [
      "index_project_open_alex_topics_on_project_id",
      "index_project_open_alex_topics_on_assignment",
    ],
  ].freeze

  test "composite indexes replace redundant foreign key indexes" do
    INDEX_PAIRS.each do |table, (removed, covering)|
      assert_index_replacement(table, removed, covering)
    end
    OPEN_ALEX_TOPIC_INDEX_PAIRS.each do |removed, covering|
      assert_index_replacement(:project_open_alex_topics, removed, covering)
    end
  end

  def assert_index_replacement(table, removed, covering)
    index_names = ActiveRecord::Base.connection.indexes(table).map(&:name)

    assert_not_includes index_names, removed, "#{removed} still exists"
    assert_includes index_names, covering, "#{covering} is missing"
  end
end
