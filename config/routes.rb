require 'sidekiq/web'
require 'sidekiq-status/web'

Sidekiq::Web.use Rack::Auth::Basic do |username, password|
  ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_USERNAME"])) &
    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_PASSWORD"]))
end if Rails.env.production?

Rails.application.routes.draw do
  mount Rswag::Ui::Engine => '/docs'
  mount Rswag::Api::Engine => '/docs'
  
  mount Sidekiq::Web => "/sidekiq"
  mount PgHero::Engine, at: "pghero"

  namespace :api, :defaults => {:format => :json} do
    namespace :v1 do
      resources :issues do
        collection do
          get :good_first_issue_counts
        end
      end
      resources :jobs
      resources :projects, constraints: { id: /.*/ }, only: [:index, :show] do
        collection do
          get :lookup
          get :packages
          get :search
          get :names
        end
        member do
          get :ping
        end
      end
    end
  end

  resources :projects, constraints: { id: /.*/ } do
    collection do
      get :lookup
      get :packages
      get :search
      get :joss
    end
    member do
      get :export
    end
    resources :releases, only: [:index, :show]
  end

  resources :releases, only: [:index]

  resources :issues, only: [:index]
  
  resources :contributors, only: [:index, :show] 

  resources :fields, only: [:index, :show]

  resources :categories, only: [:index, :show] do
    member do
      get '/:sub_category', action: :show, as: :sub_category
    end
  end

  resources :exports, only: [:index], path: 'open-data'

  get '/institutional-owners', to: 'owners#institutional', as: :institutional_owners

  resources :hosts, constraints: { id: /.*/ }, only: [:index, :show] do
    resources :owners, only: [:index, :show]
  end

  get '/404', to: 'errors#not_found'
  get '/422', to: 'errors#unprocessable'
  get '/500', to: 'errors#internal'

  root "home#index"
end
