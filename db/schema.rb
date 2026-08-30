# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_30_150000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "name"
    t.integer "projects_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "url"
  end

  create_table "contributors", force: :cascade do |t|
    t.string "categories", default: [], array: true
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "last_synced_at"
    t.string "login"
    t.string "name"
    t.json "profile", default: {}
    t.integer "reviewed_project_ids", default: [], array: true
    t.integer "reviewed_projects_count"
    t.string "sub_categories", default: [], array: true
    t.string "topics", default: [], array: true
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_contributors_on_email"
  end

  create_table "dependencies", force: :cascade do |t|
    t.float "average_ranking"
    t.integer "count"
    t.datetime "created_at", null: false
    t.string "ecosystem"
    t.string "name"
    t.json "package", default: {}
    t.integer "project_id"
    t.string "repository_url"
    t.datetime "updated_at", null: false
  end

  create_table "fields", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "domain", null: false
    t.text "indicators", default: [], array: true
    t.text "keywords", default: [], array: true
    t.string "name", null: false
    t.string "openalex_id"
    t.text "packages", default: [], array: true
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_fields_on_domain"
    t.index ["name"], name: "index_fields_on_name", unique: true
    t.index ["openalex_id"], name: "index_fields_on_openalex_id", unique: true
  end

  create_table "hosts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind"
    t.text "last_error"
    t.string "name"
    t.integer "owners_count", default: 0
    t.integer "repositories_count", default: 0
    t.integer "response_time"
    t.string "status"
    t.datetime "status_checked_at"
    t.datetime "updated_at", null: false
    t.string "url"
    t.string "version"
    t.index ["name"], name: "index_hosts_on_name", unique: true
  end

  create_table "issues", force: :cascade do |t|
    t.string "assignees"
    t.string "author_association"
    t.string "body"
    t.datetime "closed_at"
    t.string "closed_by"
    t.integer "comments_count"
    t.datetime "created_at", null: false
    t.json "dependency_metadata"
    t.string "html_url"
    t.string "labels", default: [], array: true
    t.string "labels_raw"
    t.boolean "locked"
    t.datetime "merged_at"
    t.string "node_id"
    t.integer "number"
    t.integer "project_id"
    t.boolean "pull_request"
    t.string "state"
    t.string "state_reason"
    t.integer "time_to_close"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url"
    t.string "user"
    t.string "uuid"
    t.index ["project_id"], name: "index_issues_on_project_id"
  end

  create_table "joss_vocabulary_models", force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "diagnostics", default: {}, null: false
    t.jsonb "source_counts", default: {}, null: false
    t.jsonb "term_weights", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_joss_vocabulary_models_on_created_at"
  end

  create_table "mentions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "paper_id"
    t.integer "project_id"
    t.datetime "updated_at", null: false
    t.index ["paper_id"], name: "index_mentions_on_paper_id"
    t.index ["project_id"], name: "index_mentions_on_project_id"
  end

  create_table "open_alex_topics", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "display_name", null: false
    t.string "domain_id", null: false
    t.string "domain_name", null: false
    t.string "field_id", null: false
    t.string "field_name", null: false
    t.text "keywords", default: [], null: false, array: true
    t.string "openalex_id", null: false
    t.date "source_updated_at"
    t.string "subfield_id", null: false
    t.string "subfield_name", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_open_alex_topics_on_active"
    t.index ["domain_id"], name: "index_open_alex_topics_on_domain_id"
    t.index ["field_id"], name: "index_open_alex_topics_on_field_id"
    t.index ["openalex_id"], name: "index_open_alex_topics_on_openalex_id", unique: true
    t.index ["subfield_id"], name: "index_open_alex_topics_on_subfield_id"
  end

  create_table "owners", force: :cascade do |t|
    t.string "company"
    t.datetime "created_at", null: false
    t.string "description"
    t.string "email"
    t.integer "followers"
    t.integer "following"
    t.boolean "hidden"
    t.integer "host_id"
    t.string "icon_url"
    t.citext "institutional_domain"
    t.string "kind"
    t.datetime "last_synced_at"
    t.string "location"
    t.string "login"
    t.json "metadata", default: {}
    t.string "name"
    t.integer "projects_count", default: 0, null: false
    t.datetime "repositories_checked_at"
    t.integer "repositories_count", default: 0
    t.bigint "total_stars"
    t.string "twitter"
    t.datetime "updated_at", null: false
    t.string "uuid"
    t.string "website"
    t.index "host_id, lower((login)::text)", name: "index_owners_on_host_id_lower_login", unique: true
    t.index ["host_id", "uuid"], name: "index_owners_on_host_id_uuid", unique: true
    t.index ["institutional_domain"], name: "index_owners_on_institutional_domain", where: "(institutional_domain IS NOT NULL)"
    t.index ["last_synced_at"], name: "index_owners_on_last_synced_at"
    t.index ["repositories_checked_at"], name: "index_owners_on_repositories_checked_at"
  end

  create_table "package_registries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "default", default: false, null: false
    t.string "ecosystem", null: false
    t.datetime "ecosystems_updated_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "purl_type", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index "lower((ecosystem)::text)", name: "index_package_registries_on_default_ecosystem", unique: true, where: "(\"default\" = true)"
    t.index "lower((ecosystem)::text)", name: "index_package_registries_on_lower_ecosystem"
    t.index "lower((name)::text)", name: "index_package_registries_on_lower_name", unique: true
    t.index "lower((purl_type)::text)", name: "index_package_registries_on_lower_purl_type"
    t.index "lower((url)::text)", name: "index_package_registries_on_lower_url", unique: true
  end

  create_table "packages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "ecosystems_id"
    t.datetime "ecosystems_updated_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "namespace"
    t.bigint "package_registry_id", null: false
    t.bigint "published_by_project_id"
    t.text "purl"
    t.datetime "repository_checked_at"
    t.text "repository_url"
    t.datetime "updated_at", null: false
    t.index ["ecosystems_id"], name: "index_packages_on_ecosystems_id", unique: true, where: "(ecosystems_id IS NOT NULL)"
    t.index ["package_registry_id", "name"], name: "index_packages_on_registry_and_name", unique: true
    t.index ["package_registry_id"], name: "index_packages_on_package_registry_id"
    t.index ["published_by_project_id"], name: "index_packages_on_published_by_project_id"
    t.index ["purl"], name: "index_packages_on_purl", unique: true, where: "(purl IS NOT NULL)"
    t.index ["repository_checked_at"], name: "index_packages_on_repository_checked_at"
  end

  create_table "papers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "doi"
    t.datetime "last_synced_at"
    t.integer "mentions_count", default: 0
    t.json "openalex_data"
    t.string "openalex_id"
    t.datetime "publication_date"
    t.string "title"
    t.datetime "updated_at", null: false
    t.text "urls", default: [], array: true
    t.index ["doi"], name: "index_papers_on_doi"
  end

  create_table "project_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "direct", default: false, null: false
    t.string "ecosystem", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "package_id"
    t.string "package_name", null: false
    t.bigint "project_id", null: false
    t.text "purl"
    t.datetime "updated_at", null: false
    t.index ["ecosystem", "package_name"], name: "index_project_dependencies_on_package_coordinates"
    t.index ["package_id"], name: "index_project_dependencies_on_package_id"
    t.index ["project_id", "ecosystem", "package_name"], name: "index_project_dependencies_on_unresolved_name", unique: true, where: "((package_id IS NULL) AND (purl IS NULL))"
    t.index ["project_id", "package_id"], name: "index_project_dependencies_on_resolved_package", unique: true, where: "(package_id IS NOT NULL)"
    t.index ["project_id", "purl"], name: "index_project_dependencies_on_unresolved_purl", unique: true, where: "((package_id IS NULL) AND (purl IS NOT NULL))"
    t.index ["project_id"], name: "index_project_dependencies_on_project_id"
  end

  create_table "project_fields", force: :cascade do |t|
    t.float "confidence_score", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.bigint "field_id", null: false
    t.jsonb "match_signals", default: {}
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["confidence_score"], name: "index_project_fields_on_confidence_score"
    t.index ["field_id"], name: "index_project_fields_on_field_id"
    t.index ["project_id", "field_id"], name: "index_project_fields_on_project_id_and_field_id", unique: true
    t.index ["project_id"], name: "index_project_fields_on_project_id"
  end

  create_table "project_open_alex_topics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "open_alex_topic_id", null: false
    t.string "openalex_work_id", null: false
    t.boolean "primary_topic", default: false, null: false
    t.bigint "project_id", null: false
    t.float "score", null: false
    t.string "source", null: false
    t.string "source_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["open_alex_topic_id", "score"], name: "index_project_open_alex_topics_on_topic_and_score"
    t.index ["open_alex_topic_id"], name: "index_project_open_alex_topics_on_open_alex_topic_id"
    t.index ["openalex_work_id"], name: "index_project_open_alex_topics_on_openalex_work_id"
    t.index ["project_id", "open_alex_topic_id", "source", "source_identifier"], name: "index_project_open_alex_topics_on_assignment", unique: true
    t.index ["project_id", "primary_topic"], name: "index_project_open_alex_topics_on_primary", where: "(primary_topic = true)"
    t.index ["project_id"], name: "index_project_open_alex_topics_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.jsonb "brief"
    t.string "category"
    t.text "citation_file"
    t.text "codemeta"
    t.integer "collection_id"
    t.json "commits"
    t.datetime "created_at", null: false
    t.json "dependencies"
    t.text "dependencies_index_error"
    t.datetime "dependencies_indexed_at"
    t.json "dependent_repos"
    t.string "description"
    t.boolean "esd", default: false
    t.json "events"
    t.integer "host_id"
    t.json "issues_stats"
    t.json "joss_metadata"
    t.string "keywords", default: [], array: true
    t.string "keywords_from_contributors", default: [], array: true
    t.datetime "last_synced_at"
    t.boolean "matching_criteria"
    t.integer "mentions_count", default: 0
    t.string "name"
    t.json "owner"
    t.integer "owner_id"
    t.json "packages"
    t.text "readme"
    t.json "repository"
    t.boolean "reviewed"
    t.string "rubric"
    t.float "science_score"
    t.json "science_score_breakdown", default: {}
    t.float "score", default: 0.0
    t.string "sub_category"
    t.datetime "updated_at", null: false
    t.citext "url"
    t.integer "vote_count", default: 0
    t.integer "vote_score", default: 0
    t.json "works", default: {}
    t.text "zenodo"
    t.index "((joss_metadata ->> 'doi'::text))", name: "index_projects_on_joss_doi", where: "(joss_metadata IS NOT NULL)"
    t.index ["category", "sub_category"], name: "index_projects_on_category_and_sub_category", where: "((category IS NOT NULL) AND (sub_category IS NOT NULL))"
    t.index ["collection_id"], name: "index_projects_on_collection_id"
    t.index ["host_id"], name: "index_projects_on_host_id"
    t.index ["id"], name: "index_projects_pending_dependency_index", where: "(((dependencies IS NOT NULL) OR (brief ? 'dependencies'::text)) AND (dependencies_indexed_at IS NULL) AND (dependencies_index_error IS NULL))"
    t.index ["owner_id"], name: "index_projects_on_owner_id"
    t.index ["reviewed"], name: "index_projects_on_reviewed"
    t.index ["url"], name: "index_projects_on_url", unique: true
  end

  create_table "releases", force: :cascade do |t|
    t.json "assets"
    t.string "author"
    t.text "body"
    t.datetime "created_at", null: false
    t.boolean "draft"
    t.string "html_url"
    t.datetime "last_synced_at"
    t.string "name"
    t.boolean "prerelease"
    t.integer "project_id"
    t.datetime "published_at"
    t.string "tag_name"
    t.string "tag_url"
    t.string "target_commitish"
    t.datetime "updated_at", null: false
    t.string "uuid"
    t.index ["project_id", "uuid"], name: "index_releases_on_project_id_and_uuid"
  end

  create_table "research_organization_domains", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.citext "domain", null: false
    t.string "external_id", null: false
    t.string "organization_name"
    t.text "organization_types", default: [], null: false, array: true
    t.datetime "published_at"
    t.string "source", null: false
    t.string "source_version", null: false
    t.float "strength", default: 1.0, null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_research_organization_domains_on_domain", where: "(active = true)"
    t.index ["source", "active"], name: "index_research_organization_domains_on_source_and_active"
    t.index ["source", "source_version", "domain", "external_id"], name: "index_research_domains_on_source_version_domain_id", unique: true
  end

  create_table "votes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "project_id"
    t.integer "score"
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_votes_on_project_id"
  end

  add_foreign_key "packages", "package_registries"
  add_foreign_key "packages", "projects", column: "published_by_project_id", on_delete: :nullify
  add_foreign_key "project_dependencies", "packages", on_delete: :nullify
  add_foreign_key "project_dependencies", "projects"
  add_foreign_key "project_fields", "fields"
  add_foreign_key "project_fields", "projects"
  add_foreign_key "project_open_alex_topics", "open_alex_topics"
  add_foreign_key "project_open_alex_topics", "projects"
end
