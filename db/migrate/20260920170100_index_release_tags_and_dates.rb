class IndexReleaseTagsAndDates < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :releases, [:project_id, :tag_name], algorithm: :concurrently
    add_index :releases, "COALESCE(published_at, tag_published_at) DESC NULLS LAST, id DESC",
      name: "index_releases_on_display_date", algorithm: :concurrently
    add_index :releases, "project_id, COALESCE(published_at, tag_published_at) DESC NULLS LAST, id DESC",
      name: "index_releases_on_project_display_date", algorithm: :concurrently
  end
end
