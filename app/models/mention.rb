class Mention < ApplicationRecord
  belongs_to :paper, counter_cache: true
  belongs_to :project, counter_cache: true
end
