class CreateMentions < ActiveRecord::Migration[8.0]
  def change
    create_table :mentions do |t|
      t.integer :paper_id
      t.integer :project_id

      t.timestamps
    end

    add_index :mentions, :paper_id
    add_index :mentions, :project_id
  end
end
