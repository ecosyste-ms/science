class AddMentionsCountToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :mentions_count, :integer, default: 0
  end
end
