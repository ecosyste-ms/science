class IndexPaperUrls < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :papers, :urls, using: :gin, algorithm: :concurrently
  end
end
