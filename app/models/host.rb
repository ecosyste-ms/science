class Host < ApplicationRecord
  has_many :owners
  has_many :projects

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  def self.find_by_name(name)
    return nil if name.blank?
    Host.find_by('lower(name) = ?', name.downcase)
  end

  def self.find_by_name!(name)
    host = find_by_name(name)
    raise ActiveRecord::RecordNotFound if host.nil?
    host
  end

  def to_s
    name
  end

  def to_param
    name
  end
end
