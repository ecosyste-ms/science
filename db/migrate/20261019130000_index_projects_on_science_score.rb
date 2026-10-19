class IndexProjectsOnScienceScore < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :projects, :science_score, algorithm: :concurrently
  end
end
