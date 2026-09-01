class Mention < ApplicationRecord
  belongs_to :paper
  belongs_to :project
  has_many :sources,
    class_name: "MentionSource",
    dependent: :delete_all

  counter_culture :paper
  counter_culture :project
end
