class CreateHosts < ActiveRecord::Migration[8.0]
  def change
    create_table :hosts do |t|
      t.string :name
      t.string :url
      t.string :kind
      t.integer :repositories_count, default: 0
      t.integer :owners_count, default: 0
      t.string :version
      t.string :status
      t.datetime :status_checked_at
      t.integer :response_time
      t.text :last_error

      t.timestamps
    end

    add_index :hosts, :name, unique: true
  end
end
