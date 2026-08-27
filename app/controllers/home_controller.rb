class HomeController < ApplicationController
  def index
    @stats = Rails.cache.read('homepage_stats')
  end
end
