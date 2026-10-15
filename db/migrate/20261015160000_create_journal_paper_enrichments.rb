class CreateJournalPaperEnrichments < ActiveRecord::Migration[8.1]
  def change
    create_table :journal_paper_enrichments do |t|
      t.references :paper, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.datetime :checked_at
      t.datetime :next_attempt_at, null: false
      t.string :lease_token
      t.datetime :lease_expires_at
      t.text :last_error
      t.timestamps
    end
    add_index :journal_paper_enrichments, [:next_attempt_at, :id]
    add_index :journal_paper_enrichments, [:status, :next_attempt_at]
  end
end
