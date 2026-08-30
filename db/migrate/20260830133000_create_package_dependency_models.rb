class CreatePackageDependencyModels < ActiveRecord::Migration[8.1]
  def change
    create_table :package_registries do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :ecosystem, null: false
      t.string :purl_type, null: false
      t.boolean :default, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :ecosystems_updated_at
      t.timestamps
    end

    add_index :package_registries,
      "lower(name)",
      unique: true,
      name: "index_package_registries_on_lower_name"
    add_index :package_registries,
      "lower(url)",
      unique: true,
      name: "index_package_registries_on_lower_url"
    add_index :package_registries,
      "lower(ecosystem)",
      name: "index_package_registries_on_lower_ecosystem"
    add_index :package_registries,
      "lower(purl_type)",
      name: "index_package_registries_on_lower_purl_type"
    add_index :package_registries,
      "lower(ecosystem)",
      unique: true,
      where: '"default" = true',
      name: "index_package_registries_on_default_ecosystem"

    create_table :packages do |t|
      t.references :package_registry, null: false, foreign_key: true
      t.bigint :ecosystems_id
      t.string :name, null: false
      t.string :namespace
      t.text :purl
      t.text :repository_url
      t.references :published_by_project,
        null: true,
        foreign_key: { to_table: :projects, on_delete: :nullify }
      t.jsonb :metadata, null: false, default: {}
      t.datetime :ecosystems_updated_at
      t.datetime :repository_checked_at
      t.timestamps
    end

    add_index :packages,
      %i[package_registry_id name],
      unique: true,
      name: "index_packages_on_registry_and_name"
    add_index :packages,
      :ecosystems_id,
      unique: true,
      where: "ecosystems_id IS NOT NULL"
    add_index :packages,
      :purl,
      unique: true,
      where: "purl IS NOT NULL"
    add_index :packages, :repository_checked_at

    create_table :project_dependencies do |t|
      t.references :project, null: false, foreign_key: true
      t.references :package,
        null: true,
        foreign_key: { on_delete: :nullify }
      t.text :purl
      t.string :ecosystem, null: false
      t.string :package_name, null: false
      t.boolean :direct, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :project_dependencies,
      %i[project_id package_id],
      unique: true,
      where: "package_id IS NOT NULL",
      name: "index_project_dependencies_on_resolved_package"
    add_index :project_dependencies,
      %i[project_id purl],
      unique: true,
      where: "package_id IS NULL AND purl IS NOT NULL",
      name: "index_project_dependencies_on_unresolved_purl"
    add_index :project_dependencies,
      %i[project_id ecosystem package_name],
      unique: true,
      where: "package_id IS NULL AND purl IS NULL",
      name: "index_project_dependencies_on_unresolved_name"
    add_index :project_dependencies,
      %i[ecosystem package_name],
      name: "index_project_dependencies_on_package_coordinates"
  end
end
