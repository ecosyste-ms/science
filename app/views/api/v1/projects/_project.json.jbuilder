json.extract! project, :id, :name, :description, :url, :last_synced_at, :repository, :owner, :packages, :commits, :issues_stats, :events, :keywords, :dependencies, :score, :science_score, :science_score_breakdown, :created_at, :updated_at, :avatar_url, :language, :category, :sub_category, :monthly_downloads, :funding_links, :readme_doi_urls, :arxiv_ids, :orcids, :works, :citation_counts, :total_citations, :keywords_from_contributors
json.project_url api_v1_project_url(project, format: :json)
json.html_url project_url(project)
if project.citation_file.present?
  json.bibtex_url export_project_url(project, format: 'bibtex')
  json.apalike_url export_project_url(project, format: 'apalike')
end
json.fields project.open_alex_fields_with_scores do |field, score|
  json.id field.openalex_id
  json.name field.name
  json.domain field.domain_display_name
  json.score score.round(6)
end
