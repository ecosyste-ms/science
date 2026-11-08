class AddJevReviewOutcomes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :jev_discoveries, :review_purpose, :string
    add_column :jev_discoveries, :review_implementation, :string
    add_column :jev_discoveries, :review_catalogue_value, :string
    %w[review_purpose review_implementation review_catalogue_value].each do |column|
      add_index :jev_discoveries, [:jev_run_id, column, :id], where: "#{column} IS NOT NULL",
        name: "index_jev_discoveries_#{column}", algorithm: :concurrently
    end
  end
end
