class CreateJossVocabularyModels < ActiveRecord::Migration[8.1]
  def change
    create_table :joss_vocabulary_models do |t|
      t.jsonb :term_weights, null: false, default: {}
      t.jsonb :config, null: false, default: {}
      t.jsonb :source_counts, null: false, default: {}
      t.jsonb :diagnostics, null: false, default: {}
      t.timestamps
    end

    add_index :joss_vocabulary_models, :created_at
  end
end
