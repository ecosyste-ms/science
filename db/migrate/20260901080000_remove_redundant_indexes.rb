class RemoveRedundantIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    packages: {
      name: "index_packages_on_package_registry_id",
      column: :package_registry_id,
    },
    project_authors: {
      name: "index_project_authors_on_project_id",
      column: :project_id,
    },
    project_contributors: {
      name: "index_project_contributors_on_project_id",
      column: :project_id,
    },
    project_fields: {
      name: "index_project_fields_on_project_id",
      column: :project_id,
    },
    project_open_alex_topics: [
      {
        name: "index_project_open_alex_topics_on_open_alex_topic_id",
        column: :open_alex_topic_id,
      },
      {
        name: "index_project_open_alex_topics_on_project_id",
        column: :project_id,
      },
    ],
    project_repository_aliases: {
      name: "index_project_repository_aliases_on_project_id",
      column: :project_id,
    },
  }.freeze

  def up
    INDEXES.each do |table, definitions|
      Array.wrap(definitions).each do |definition|
        remove_index table,
          name: definition.fetch(:name),
          algorithm: :concurrently
      end
    end
  end

  def down
    INDEXES.each do |table, definitions|
      Array.wrap(definitions).each do |definition|
        add_index table,
          definition.fetch(:column),
          name: definition.fetch(:name),
          algorithm: :concurrently
      end
    end
  end
end
