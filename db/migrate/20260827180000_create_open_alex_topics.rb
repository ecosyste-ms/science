class CreateOpenAlexTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :open_alex_topics do |t|
      t.string :openalex_id, null: false
      t.string :display_name, null: false
      t.text :description
      t.text :keywords, array: true, default: [], null: false
      t.string :subfield_id, null: false
      t.string :subfield_name, null: false
      t.string :field_id, null: false
      t.string :field_name, null: false
      t.string :domain_id, null: false
      t.string :domain_name, null: false
      t.date :source_updated_at
      t.boolean :active, default: true, null: false
      t.timestamps
    end

    add_index :open_alex_topics, :openalex_id, unique: true
    add_index :open_alex_topics, :subfield_id
    add_index :open_alex_topics, :field_id
    add_index :open_alex_topics, :domain_id
    add_index :open_alex_topics, :active

    create_table :project_open_alex_topics do |t|
      t.references :project, null: false, foreign_key: true
      t.references :open_alex_topic, null: false, foreign_key: true
      t.float :score, null: false
      t.boolean :primary_topic, default: false, null: false
      t.string :source, null: false
      t.string :source_identifier, null: false
      t.string :openalex_work_id, null: false
      t.timestamps
    end

    add_index :project_open_alex_topics,
      %i[project_id open_alex_topic_id source source_identifier],
      unique: true,
      name: "index_project_open_alex_topics_on_assignment"
    add_index :project_open_alex_topics,
      %i[open_alex_topic_id score],
      name: "index_project_open_alex_topics_on_topic_and_score"
    add_index :project_open_alex_topics,
      %i[project_id primary_topic],
      where: "primary_topic = true",
      name: "index_project_open_alex_topics_on_primary"
    add_index :project_open_alex_topics, :openalex_work_id

    add_index :projects,
      "(joss_metadata ->> 'doi')",
      where: "joss_metadata IS NOT NULL",
      name: "index_projects_on_joss_doi"
  end
end
