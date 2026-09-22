require "tempfile"
require "timeout"

class RepositoryCommand
  class Error < StandardError; end

  def initialize(timeout: 120, output_limit: 65_536)
    @timeout = timeout
    @output_limit = output_limit
  end

  def run(command, input: File::NULL)
    Tempfile.create("repository-stdout") do |stdout|
      Tempfile.create("repository-stderr") do |stderr|
        pid = Process.spawn({ "GIT_TERMINAL_PROMPT" => "0" }, *command, in: input, out: stdout, err: stderr, pgroup: true)
        begin
          _, status = Timeout.timeout(@timeout) { Process.wait2(pid) }
        rescue Timeout::Error
          Process.kill("KILL", -pid) rescue Errno::ESRCH
          Process.wait(pid) rescue Errno::ECHILD
          raise Error, "command timed out after #{@timeout} seconds"
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
end
