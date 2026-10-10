require "tempfile"
require "timeout"

class RepositoryCommand
  class Error < StandardError; end

  def initialize(timeout: 120, output_limit: 65_536, disk_path: nil, disk_limit: nil)
    @timeout = timeout
    @output_limit = output_limit
    @disk_path = disk_path
    @disk_limit = disk_limit
  end

  def run(command, input: File::NULL)
    Tempfile.create("repository-stdout") do |stdout|
      Tempfile.create("repository-stderr") do |stderr|
        pid = Process.spawn({ "GIT_TERMINAL_PROMPT" => "0" }, *command, in: input, out: stdout, err: stderr, pgroup: true)
        begin
          _, status = Timeout.timeout(@timeout) do
            if @disk_limit
              loop do
                check_disk_limit!
                result = Process.wait2(pid, Process::WNOHANG)
                break result if result
                sleep 0.1
              end
            else
              Process.wait2(pid)
            end
          end
        rescue Timeout::Error, Error => error
          Process.kill("KILL", -pid) rescue Errno::ESRCH
          Process.wait(pid) rescue Errno::ECHILD
          raise Error, error.is_a?(Timeout::Error) ? "command timed out after #{@timeout} seconds" : error.message
        end
        stderr.rewind
        unless status.success?
          message = stderr.read(500).to_s.force_encoding(Encoding::UTF_8).scrub.strip
          raise Error, "command failed (exit #{status.exitstatus || 'signal'}): #{message}"
        end
        stdout.rewind
        output = stdout.read(@output_limit + 1).to_s
        raise Error, "command output exceeds #{@output_limit} bytes" if output.bytesize > @output_limit

        output
      end
    end
  end

  def check_disk_limit!
    size = Dir.glob(File.join(@disk_path, "**", "*"), File::FNM_DOTMATCH).sum do |path|
      stat = File.lstat(path)
      stat.file? ? stat.size : 0
    rescue Errno::ENOENT
      0
    end
    raise Error, "repository disk limit exceeded" if size > @disk_limit
  end
end
