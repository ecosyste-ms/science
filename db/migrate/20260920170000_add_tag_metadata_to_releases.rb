class AddTagMetadataToReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :releases, :tag_sha, :string
    add_column :releases, :tag_kind, :string
    add_column :releases, :tag_published_at, :datetime
    add_column :releases, :tag_html_url, :text
    add_column :releases, :download_url, :text
    add_column :releases, :purl, :text
    add_column :releases, :manifests_url, :text
    add_column :releases, :tag_fetched_at, :datetime
    add_column :releases, :release_fetched_at, :datetime
    add_column :releases, :forge_created_at, :datetime
    add_column :releases, :release_url, :text
    add_column :releases, :immutable, :boolean
    add_column :projects, :release_sync_state, :jsonb, default: {}, null: false
  end
end
