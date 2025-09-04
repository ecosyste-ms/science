class CategoriesController < ApplicationController
  def index
    @categories = Project.category_tree
  end

  def show
    @categories = Project.category_tree
    @category = params[:id]
    if params[:sub_category]  
      @sub_category = params[:sub_category]
      project_scope = Project.where(category: @category, sub_category: @sub_category).order('score DESC')
      contributor_scope = Contributor.category(@category).sub_category(@sub_category).display.order('name ASC')
    else
      project_scope = Project.where(category: @category).order('score DESC')
      contributor_scope = Contributor.category(@category).display.order('name ASC')
    end
    @sub_categories = @categories.find { |category| category[:category] == @category }[:sub_categories]
    
    @pagy, @projects = pagy(project_scope)
    @contributors_pagy, @contributors = pagy(contributor_scope)
  end
end