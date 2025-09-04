class AddScientificDomainToProjects < ActiveRecord::Migration[7.0]
  def change
    add_column :projects, :scientific_domain, :string
  end
end
