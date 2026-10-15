require "shellwords"

module JournalSchedule
  def scheduled_journal_tasks(source, action)
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .select { |entry| Shellwords.split(entry.fetch("command")).include?("#{source}:#{action}") }.sole
    commands = Shellwords.split(cron.fetch("command"))
    assert_equal %w[bundle exec rake], commands.first(3)
    output, = capture_io do
      commands.drop(3).each do |name|
        Rake::Task[name].reenable
        Rake::Task[name].invoke
      end
    end
    output.lines.map { |line| JSON.parse(line) }
  end
end
