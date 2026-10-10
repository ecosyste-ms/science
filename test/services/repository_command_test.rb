require "test_helper"
require "tmpdir"

class RepositoryCommandTest < ActiveSupport::TestCase
  test "timeout kills the command process while monitoring repository size" do
    Dir.mktmpdir do |directory|
      pid_file = File.join(directory, "pid")
      command = [RbConfig.ruby, "-e", "File.write(ARGV[0], Process.pid); sleep 30", pid_file]
      error = assert_raises(RepositoryCommand::Error) do
        RepositoryCommand.new(timeout: 0.5, disk_path: directory, disk_limit: 1024).run(command)
      end
      assert_match(/timed out/, error.message)
      pid = Integer(File.read(pid_file))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  test "disk limit kills a running writer and reports a bounded error" do
    Dir.mktmpdir do |directory|
      pid_file = File.join(directory, "pid")
      command = [RbConfig.ruby, "-e",
        "File.write(ARGV[0], Process.pid); File.write(ARGV[1], 'x' * 2048); sleep 30",
        pid_file, File.join(directory, "pack")]
      error = assert_raises(RepositoryCommand::Error) do
        RepositoryCommand.new(timeout: 5, disk_path: directory, disk_limit: 1024).run(command)
      end
      assert_equal "repository disk limit exceeded", error.message
      pid = Integer(File.read(pid_file))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end
end
