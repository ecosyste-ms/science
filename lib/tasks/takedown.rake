namespace :takedown do
  desc "Hide a user and remove their projects. LOGIN=username [HOST=GitHub]"
  task hide_user: :environment do
    login = ENV['LOGIN']
    host_name = ENV['HOST'] || 'GitHub'
    abort "LOGIN is required" if login.blank?

    host = Host.find_by_name(host_name)
    abort "Host #{host_name} not found" if host.nil?

    owner = nil
    project_count = 0
    contributor_count = 0

    ActiveRecord::Base.transaction do
      owner = host.owners.find_by('lower(login) = ?', login.downcase)
      owner ||= host.owners.create!(login: login.downcase)
      owner.hide!

      projects = Project.for_owner(host, login)
      project_count = projects.count
      projects.find_each(&:destroy!)

      contributors = Contributor.where(
        "lower(login) = :login OR lower(profile ->> 'login') = :login",
        login: login.downcase
      )
      contributor_count = contributors.count
      contributors.delete_all

      owner.update!(projects_count: 0)
    end

    puts "[science] hidden owner #{host.name}/#{owner.login}"
    puts "[science] destroyed #{project_count} projects for #{host.name}/#{login}"
    puts "[science] destroyed #{contributor_count} contributors for #{login}"
  end

  desc "Report what exists for a user. LOGIN=username [HOST=GitHub]"
  task report: :environment do
    login = ENV['LOGIN']
    host_name = ENV['HOST'] || 'GitHub'
    abort "LOGIN is required" if login.blank?

    host = Host.find_by_name(host_name)
    abort "Host #{host_name} not found" if host.nil?

    owner = host.owners.find_by('lower(login) = ?', login.downcase)
    project_count = Project.for_owner(host, login).count
    contributor_count = Contributor.where(
      "lower(login) = :login OR lower(profile ->> 'login') = :login",
      login: login.downcase
    ).count
    state = owner ? (owner.hidden? ? 'hidden' : 'visible') : 'none'

    puts "[science] #{host.name}/#{login}: owner=#{state} projects=#{project_count} contributors=#{contributor_count}"
  end
end
