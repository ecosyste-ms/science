require "digest"
require "json"
require "tempfile"
require "timeout"
require "time"

class SwhidCalculator
  TYPES = { "content" => "cnt", "directory" => "dir", "revision" => "rev" }.freeze
  TIMEOUT = 120
  OUTPUT_LIMIT = 65_536
  ERROR_LIMIT = 500

  class CommandError < StandardError; end

  def initialize(binary: "swhid", timeout: TIMEOUT)
    @binary = binary
    @timeout = timeout
  end

  def calculate(type:, path:, ref: nil, origin: nil, artifact: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = {
      "method" => "swhid-go/#{type}",
      "attempted_at" => Time.now.utc.iso8601,
      "input" => { "path" => File.expand_path(path), "ref" => ref, "origin" => origin }.compact
    }
    raise ArgumentError, "type must be #{TYPES.keys.join(', ')}" unless TYPES.key?(type)
    raise ArgumentError, "ref is only supported for revision" if ref && type != "revision"
    raise ArgumentError, "artifact is only supported for directory" if artifact && type != "directory"

    command = [@binary, type, "--format", "json"]
    command << result["input"]["path"] unless type == "content"
    command << (ref || "HEAD") if type == "revision"
    result["command"] = command
    result["binary_version"] = run([@binary, "--version"]).strip

    if type == "content"
      File.open(path, "rb") do |input|
        digest = Digest::SHA256.new
        while (chunk = input.read(65_536))
          digest.update(chunk)
        end
        result["input"]["sha256"] = digest.hexdigest
        input.rewind
        result["swhid"] = identifier(run(command, input: input), type)
      end
    else
      if artifact
        result["input"]["artifact_path"] = File.expand_path(artifact)
        result["input"]["artifact_sha256"] = Digest::SHA256.file(artifact).hexdigest
      end
      result["swhid"] = identifier(run(command), type)
    end
    result["status"] = "success"
    result
  rescue ArgumentError, CommandError, JSON::ParserError, SystemCallError => error
    result.merge!("status" => "error", "error" => error.message.to_s.scrub[0, ERROR_LIMIT])
  ensure
    result["duration_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round if result
  end

  def identifier(output, type)
    data = JSON.parse(output)
    value = data["swhid"] if data.is_a?(Hash)
    unless value.is_a?(String) && value.match?(/\Aswh:1:#{TYPES.fetch(type)}:[0-9a-f]{40}\z/)
      raise CommandError, "swhid returned an invalid #{type} identifier"
    end
    value
  end

  def run(command, input: File::NULL)
    Tempfile.create("swhid-stdout") do |stdout|
      Tempfile.create("swhid-stderr") do |stderr|
        pid = Process.spawn({ "GIT_TERMINAL_PROMPT" => "0" }, *command, in: input, out: stdout, err: stderr, pgroup: true)
        begin
          _, status = Timeout.timeout(@timeout) { Process.wait2(pid) }
        rescue Timeout::Error
          Process.kill("KILL", -pid) rescue Errno::ESRCH
          Process.wait(pid) rescue Errno::ECHILD
          raise CommandError, "command timed out after #{@timeout} seconds"
        end
        stderr.rewind
        unless status.success?
          message = stderr.read(ERROR_LIMIT).to_s.force_encoding(Encoding::UTF_8).scrub.strip
          raise CommandError, "command failed (exit #{status.exitstatus || 'signal'}): #{message}"
        end
        stdout.rewind
        output = stdout.read(OUTPUT_LIMIT + 1).to_s
        raise CommandError, "command output exceeds #{OUTPUT_LIMIT} bytes" if output.bytesize > OUTPUT_LIMIT

        output
      end
    end
  end
end
