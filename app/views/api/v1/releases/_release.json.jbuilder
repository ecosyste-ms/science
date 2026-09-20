json.extract! release, :id, :project_id, :tag_name, :tag_sha, :tag_kind,
  :tag_published_at, :tag_html_url, :download_url, :purl, :manifests_url,
  :uuid, :name, :body, :target_commitish, :published_at, :forge_created_at,
  :author, :assets, :draft, :prerelease, :immutable, :html_url, :tag_url,
  :release_url, :last_synced_at, :tag_fetched_at, :release_fetched_at
json.forge_release release.forge_release?
json.api_url api_v1_project_release_url(release.project_id, release)
