class ModelsController < ApplicationController
  def index
    @index = ModelProjectIndex.new(params)
    @pagy, @projects = pagy(@index.scope, limit: 20)
  end
end
