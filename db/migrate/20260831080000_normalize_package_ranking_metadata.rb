class NormalizePackageRankingMetadata < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :packages, :general_dependent_repositories_count, :bigint
    add_column :packages, :dependent_repositories_top_percentage, :float
    add_column :packages, :average_top_percentage, :float
    add_column :packages, :ranking_metadata_normalized_at, :datetime

    add_index :packages,
      :ranking_metadata_normalized_at,
      where: "ranking_metadata_normalized_at IS NULL",
      algorithm: :concurrently,
      name: "index_packages_pending_ranking_metadata_normalization"
    add_index :project_dependencies,
      [:project_id, :package_id],
      where: "direct AND package_id IS NOT NULL",
      algorithm: :concurrently,
      name: "index_project_dependencies_on_direct_resolved_package"
  end
end
