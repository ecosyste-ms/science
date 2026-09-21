json.extract! package_version, :id, :package_id, :ecosystems_id, :number,
  :published_at, :ecosystems_created_at, :ecosystems_updated_at, :fetched_at,
  :licenses, :integrity, :status, :immutable, :download_url, :registry_url,
  :documentation_url, :purl, :metadata, :related_tag, :release_id
json.release_match_method package_version.release_id ? package_version.release_match_method : nil
json.api_url api_v1_package_version_url(package_version.package_id, package_version)
