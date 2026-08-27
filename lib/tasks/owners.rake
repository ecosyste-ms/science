namespace :owners do
  desc 'check ROR owner repository inventories'
  task check_ror_repositories: :environment do
    limit = Integer(ENV.fetch('LIMIT', '25'), 10)
    raise ArgumentError, 'LIMIT must be greater than zero' unless limit.positive?

    checked = Owner.check_ror_repositories(limit: limit)
    puts "Checked repositories for #{checked} ROR owners"
  rescue ArgumentError => error
    abort error.message
  end
end
