class IndexProjectsOnKeywords < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :projects, :keywords, using: :gin, algorithm: :concurrently
  end
end
