class AddRepositoriesCheckedAtToOwners < ActiveRecord::Migration[8.1]
  def change
    add_column :owners, :repositories_checked_at, :datetime
    add_index :owners, :repositories_checked_at
  end
end
