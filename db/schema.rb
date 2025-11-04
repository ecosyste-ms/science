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

ActiveRecord::Schema[8.0].define(version: 2025_11_04_152721) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "collections", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.string "url"
    t.integer "projects_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "contributors", force: :cascade do |t|
    t.string "name"
    t.string "email"
    t.string "login"
    t.string "topics", default: [], array: true
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "categories", default: [], array: true
    t.string "sub_categories", default: [], array: true
    t.integer "reviewed_project_ids", default: [], array: true
    t.integer "reviewed_projects_count"
    t.json "profile", default: {}
  end

  create_table "dependencies", force: :cascade do |t|
    t.string "ecosystem"
    t.string "name"
    t.integer "count"
    t.json "package", default: {}
    t.string "repository_url"
    t.integer "project_id"
    t.float "average_ranking"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "fields", force: :cascade do |t|
    t.string "name", null: false
    t.string "domain", null: false
    t.string "openalex_id"
    t.text "description"
    t.text "keywords", default: [], array: true
    t.text "packages", default: [], array: true
    t.text "indicators", default: [], array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_fields_on_domain"
    t.index ["name"], name: "index_fields_on_name", unique: true
    t.index ["openalex_id"], name: "index_fields_on_openalex_id", unique: true
  end

  create_table "hosts", force: :cascade do |t|
    t.string "name"
    t.string "url"
    t.string "kind"
    t.integer "repositories_count", default: 0
    t.integer "owners_count", default: 0
    t.string "version"
    t.string "status"
    t.datetime "status_checked_at"
    t.integer "response_time"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_hosts_on_name", unique: true
  end

  create_table "issues", force: :cascade do |t|
    t.integer "project_id"
    t.string "uuid"
    t.string "node_id"
    t.integer "number"
    t.string "state"
    t.string "title"
    t.string "body"
    t.string "user"
    t.string "labels_raw"
    t.string "assignees"
    t.boolean "locked"
    t.integer "comments_count"
    t.boolean "pull_request"
    t.datetime "closed_at"
    t.string "closed_by"
    t.string "author_association"
    t.string "state_reason"
    t.integer "time_to_close"
    t.datetime "merged_at"
    t.json "dependency_metadata"
    t.string "html_url"
    t.string "url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "labels", default: [], array: true
    t.index ["project_id"], name: "index_issues_on_project_id"
  end

  create_table "mentions", force: :cascade do |t|
    t.integer "paper_id"
    t.integer "project_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["paper_id"], name: "index_mentions_on_paper_id"
    t.index ["project_id"], name: "index_mentions_on_project_id"
  end

  create_table "owners", force: :cascade do |t|
    t.integer "host_id"
    t.string "login"
    t.string "name"
    t.string "uuid"
    t.string "kind"
    t.string "description"
    t.string "email"
    t.string "website"
    t.string "location"
    t.string "twitter"
    t.string "company"
    t.string "icon_url"
    t.integer "repositories_count", default: 0
    t.datetime "last_synced_at"
    t.json "metadata", default: {}
    t.bigint "total_stars"
    t.integer "followers"
    t.integer "following"
    t.boolean "hidden"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "projects_count", default: 0, null: false
    t.index "host_id, lower((login)::text)", name: "index_owners_on_host_id_lower_login", unique: true
    t.index ["host_id", "uuid"], name: "index_owners_on_host_id_uuid", unique: true
    t.index ["last_synced_at"], name: "index_owners_on_last_synced_at"
  end

  create_table "papers", force: :cascade do |t|
    t.string "doi"
    t.string "openalex_id"
    t.string "title"
    t.datetime "publication_date"
    t.json "openalex_data"
    t.integer "mentions_count", default: 0
    t.datetime "last_synced_at"
    t.text "urls", default: [], array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["doi"], name: "index_papers_on_doi"
  end

  create_table "project_fields", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "field_id", null: false
    t.float "confidence_score", default: 0.0, null: false
    t.jsonb "match_signals", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confidence_score"], name: "index_project_fields_on_confidence_score"
    t.index ["field_id"], name: "index_project_fields_on_field_id"
    t.index ["project_id", "field_id"], name: "index_project_fields_on_project_id_and_field_id", unique: true
    t.index ["project_id"], name: "index_project_fields_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.citext "url"
    t.json "repository"
    t.json "packages"
    t.json "commits"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "dependent_repos"
    t.integer "collection_id"
    t.json "events"
    t.string "keywords", default: [], array: true
    t.json "dependencies"
    t.datetime "last_synced_at"
    t.json "issues_stats"
    t.float "score", default: 0.0
    t.json "owner"
    t.string "name"
    t.string "description"
    t.boolean "reviewed"
    t.boolean "matching_criteria"
    t.string "rubric"
    t.integer "vote_count", default: 0
    t.integer "vote_score", default: 0
    t.text "citation_file"
    t.string "category"
    t.string "sub_category"
    t.text "readme"
    t.json "works", default: {}
    t.string "keywords_from_contributors", default: [], array: true
    t.boolean "esd", default: false
    t.json "joss_metadata"
    t.float "science_score"
    t.json "science_score_breakdown", default: {}
    t.integer "mentions_count", default: 0
    t.integer "host_id"
    t.integer "owner_id"
    t.text "codemeta"
    t.index ["category", "sub_category"], name: "index_projects_on_category_and_sub_category", where: "((category IS NOT NULL) AND (sub_category IS NOT NULL))"
    t.index ["collection_id"], name: "index_projects_on_collection_id"
    t.index ["host_id"], name: "index_projects_on_host_id"
    t.index ["owner_id"], name: "index_projects_on_owner_id"
    t.index ["reviewed"], name: "index_projects_on_reviewed"
    t.index ["url"], name: "index_projects_on_url", unique: true
  end

  create_table "releases", force: :cascade do |t|
    t.integer "project_id"
    t.string "uuid"
    t.string "tag_name"
    t.string "target_commitish"
    t.string "name"
    t.text "body"
    t.boolean "draft"
    t.boolean "prerelease"
    t.datetime "published_at"
    t.string "author"
    t.json "assets"
    t.datetime "last_synced_at"
    t.string "tag_url"
    t.string "html_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "votes", force: :cascade do |t|
    t.integer "project_id"
    t.integer "score"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_votes_on_project_id"
  end

  add_foreign_key "project_fields", "fields"
  add_foreign_key "project_fields", "projects"
end
