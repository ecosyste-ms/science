require "tmpdir"
require "shellwords"

class RepositoryCheckout
  DISK_LIMIT_ERROR = "repository disk limit exceeded".freeze
  PARTIAL_BLOB_LIMIT = 1.megabyte

  attr_reader :command, :skipped_paths

  def initialize(origin, revision: nil, skip_lfs: false, disk_limit: 500.megabytes, partial: false)
    raise ArgumentError, "Expected a full commit SHA" if revision && !revision.match?(/\A[0-9a-f]{40}\z/)

    @origin = origin
    @revision = revision
    @skip_lfs = skip_lfs
    @disk_limit = disk_limit
    @partial = partial
    @skipped_paths = 0
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
      elsif @partial
        @command = [*git, "clone", "--depth", "1", "--no-tags", "--filter=blob:limit=#{PARTIAL_BLOB_LIMIT}", "--no-checkout", "--", @origin, checkout]
        runner.run(command)
        sparse_checkout(git, checkout, directory)
      else
        @command = [*git, "clone", "--depth", "1", "--no-tags", "--", @origin, checkout]
        runner.run(command)
      end
      runner.check_disk_limit!
      yield checkout, @origin, command
    end
  end

  # Checks out everything except the blobs the filtered clone left on the server, so they are never fetched.
  def sparse_checkout(git, checkout, directory)
    runner = RepositoryCommand.new(output_limit: 64.megabytes, disk_path: directory, disk_limit: @disk_limit)
    missing = runner.run([*git, "-C", checkout, "rev-list", "--objects", "--missing=print", "HEAD"])
      .each_line.filter_map { |line| line.strip.delete_prefix("?") if line.start_with?("?") }.to_set
    paths = runner.run([*git, "-C", checkout, "ls-tree", "-r", "-z", "HEAD"]).split("\0").filter_map do |entry|
      info, path = entry.split("\t", 2)
      path if missing.include?(info.split(" ")[2])
    end
    @skipped_paths = paths.size
    patterns = File.join(directory, "sparse-patterns")
    File.binwrite(patterns, ["/*", *paths.map { |path| "!/#{path.gsub(/[\\*?\[\]!# ]/) { |char| "\\#{char}" }}" }].join("\n") + "\n")
    runner.run([*git, "-C", checkout, "sparse-checkout", "set", "--no-cone", "--stdin"], input: patterns)
    runner.run([*git, "-C", checkout, "checkout", "--quiet"])
  end
end
