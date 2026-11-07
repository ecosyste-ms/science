class Jev::Request < ApplicationRecord
  belongs_to :run, class_name: "Jev::Run", foreign_key: :jev_run_id
  validates :digest, presence: true
end
