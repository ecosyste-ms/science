require "tmpdir"
require "shellwords"

class RepositoryCheckout
  attr_reader :command

  def initialize(origin, revision: nil, skip_lfs: false, disk_limit: 500.megabytes)
    raise ArgumentError, "Expected a full commit SHA" if revision && !revision.match?(/\A[0-9a-f]{40}\z/)

    @origin = origin
    @revision = revision
    @skip_lfs = skip_lfs
    @disk_limit = disk_limit
  end

  def self.credentials(origin)
    uri = URI.parse(origin)
    return ["-c", "credential.helper="] unless ENV["GITHUB_TOKEN"].present? && uri.scheme == "https" &&
      uri.host&.downcase == "github.com" && uri.port == 443 && uri.userinfo.nil?

    helper = "!#{Shellwords.join([RbConfig.ruby, Rails.root.join('bin/git-credential-github').to_s])}"
    ["-c", "credential.helper=", "-c", "credential.helper=#{helper}"]
  rescue URI::InvalidURIError
    ["-c", "credential.helper="]
  end

  def open
    Dir.mktmpdir("science-repository-") do |directory|
      checkout = File.join(directory, "repository")
      runner = RepositoryCommand.new(disk_path: directory, disk_limit: @disk_limit)
      git = ["git", *self.class.credentials(@origin)]
      git += ["-c", "filter.lfs.process=", "-c", "filter.lfs.smudge=", "-c", "filter.lfs.required=false"] if @skip_lfs
      if @revision
        runner.run([*git, "init", checkout])
        @command = [*git, "-C", checkout, "fetch", "--depth", "1", "--no-tags", "--", @origin, @revision]
        runner.run(command)
        runner.run([*git, "-C", checkout, "checkout", "--detach", @revision])
        actual = runner.run([*git, "-C", checkout, "rev-parse", "HEAD"]).strip
        raise RepositoryCommand::Error, "Checkout does not match requested revision" unless actual == @revision
      else
        @command = [*git, "clone", "--depth", "1", "--no-tags", "--", @origin, checkout]
        runner.run(command)
      end
      runner.check_disk_limit!
      yield checkout, @origin, command
    end
  end
end
