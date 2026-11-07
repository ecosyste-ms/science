class AddWireBodyToJevRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :jev_requests, :wire_body, :text
  end
end
