class CreateJevDiscovery < ActiveRecord::Migration[8.1]
  def change
    create_table :jev_runs do |t|
      t.string :name, null: false
      t.string :status, null: false, default: "running"
      t.string :seed, null: false
      t.integer :target_count, null: false
      t.boolean :sampling_complete, null: false, default: false
      t.jsonb :sampling_state, null: false, default: {}
      t.jsonb :settings, null: false, default: {}
      t.decimal :budget_usd, precision: 14, scale: 8, null: false
      t.decimal :spent_usd, precision: 14, scale: 8, null: false, default: 0
      t.decimal :reserved_usd, precision: 14, scale: 8, null: false, default: 0
      t.text :last_error
      t.datetime :completed_at
      t.timestamps
    end
    add_index :jev_runs, :name, unique: true
    add_index :jev_runs, :status

    create_table :jev_requests do |t|
      t.references :jev_run, null: false, foreign_key: true
      t.string :digest, null: false
      t.string :cache_digest, null: false
      t.string :stage, null: false
      t.string :model, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :question_versions, null: false, default: {}
      t.jsonb :request_body, null: false, default: {}
      t.jsonb :response_body, null: false, default: {}
      t.jsonb :attempt_log, null: false, default: []
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :attempts, null: false, default: 0
      t.decimal :cost_usd, precision: 14, scale: 8, null: false, default: 0
      t.decimal :reserved_usd, precision: 14, scale: 8, null: false, default: 0
      t.float :latency_ms
      t.text :last_error
      t.datetime :completed_at
      t.timestamps
    end
    add_index :jev_requests, :digest, unique: true
    add_index :jev_requests, [:cache_digest, :status]
    add_index :jev_requests, [:jev_run_id, :stage, :status]

    create_table :jev_discoveries do |t|
      t.references :jev_run, null: false, foreign_key: true
      t.references :project, foreign_key: { on_delete: :nullify }
      t.string :repository_url, null: false
      t.string :source, null: false
      t.string :sampling_method, null: false
      t.string :sample_group, null: false
      t.jsonb :source_metadata, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.string :evidence_fingerprint
      t.string :status, null: false, default: "pending_screen"
      t.string :classification, null: false, default: "uncertain"
      t.float :strict_probability
      t.float :implementation_probability
      t.references :screen_request, foreign_key: { to_table: :jev_requests }
      t.references :enrich_request, foreign_key: { to_table: :jev_requests }
      t.string :screen_band
      t.boolean :control, null: false, default: false
      t.float :control_probability
      t.boolean :enrichment_selected, null: false, default: false
      t.string :enrichment_reason
      t.integer :screen_attempts, null: false, default: 0
      t.integer :enrich_attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :lease_until
      t.string :processing_token
      t.text :last_error
      t.text :enrichment_error
      t.datetime :screened_at
      t.datetime :enriched_at
      t.datetime :next_check_at
      t.string :review_state, null: false, default: "unreviewed"
      t.text :review_notes
      t.string :reviewed_by
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :jev_discoveries, [:jev_run_id, :repository_url], unique: true
    add_index :jev_discoveries, [:jev_run_id, :status, :next_attempt_at], name: "index_jev_discoveries_due"
    add_index :jev_discoveries, [:jev_run_id, :classification, :review_state], name: "index_jev_discoveries_review"
    add_index :jev_discoveries, :lease_until
    add_index :jev_discoveries, :next_check_at
  end
end
