require "open3"
require "tempfile"
require "timeout"

class JournalPackageMetadata
  def self.read(body, name:, ecosystem:)
    Tempfile.create(["journal-package", ".archive"]) do |file|
      file.binmode
      file.write(body)
      file.flush
      listing = archive_output(["bsdtar", "-tf", file.path])
      field_file = ecosystem == "cran" ? "DESCRIPTION" : "PKG-INFO"
      names = listing.lines.map(&:strip).select do |path|
        parts = path.split("/")
        parts.size == 2 && parts.last == field_file && parts.first.match?(/\A[a-zA-Z0-9_.-]+\z/) && !%w[. ..].include?(parts.first)
      end.uniq
      return { "status" => "unresolved", "reason" => "missing or ambiguous root package metadata" } unless names.one?
      contents = archive_output(["bsdtar", "-xOf", file.path, names.sole])
      fields = headers(contents)
      actual_names = fields[ecosystem == "cran" ? "Package" : "Name"]
      actual = actual_names.first if actual_names.one?
      normalize = ->(value) { ecosystem == "pypi" ? value.to_s.downcase.gsub(/[-_.]+/, "-") : value.to_s.downcase }
      unless actual.present? && normalize.call(actual) == normalize.call(name)
        return { "status" => "unresolved", "reason" => "package name disagrees with publisher label", "metadata_name" => actual }
      end
      keys = ecosystem == "cran" ? %w[URL BugReports] : %w[Home-page Project-URL]
      urls = keys.flat_map { |key| Array(fields[key]).flat_map { |value| value.scan(%r{https?://[^\s,<>]+}).map { |url| url.sub(/[);.]+\z/, "") } } }.uniq
      { "status" => "matched", "name" => actual, "ecosystem" => ecosystem,
        "metadata_file" => names.sole, "fields" => fields.slice(*keys), "urls" => urls }
    end
  rescue ArgumentError, Timeout::Error => error
    { "status" => "unresolved", "reason" => error.message }
  end

  def self.headers(text)
    fields = Hash.new { |hash, key| hash[key] = [] }
    current = nil
    text.encode("UTF-8", invalid: :replace, undef: :replace).each_line do |line|
      break if line.strip.empty?
      if (match = line.match(/\A([A-Za-z][A-Za-z0-9-]*):\s*(.*)/))
        current = match[1]
        fields[current] << match[2].strip
      elsif current && line.match?(/\A\s/)
        fields[current][-1] += " #{line.strip}"
      end
    end
    fields
  end

  def self.archive_output(command)
    Open3.popen3(*command) do |stdin, stdout, stderr, thread|
      stdin.close
      error_reader = Thread.new { stderr.read(8192) }
      begin
        Timeout.timeout(10) do
          output = stdout.read(256.kilobytes + 1)
          raise ArgumentError, "package metadata exceeds 256 KB" if output.bytesize > 256.kilobytes
          raise ArgumentError, "unsupported or invalid package archive" unless thread.value.success?
          output
        end
      ensure
        Process.kill("KILL", thread.pid) if thread.alive?
        thread.join
        error_reader.join
        stderr.close unless stderr.closed?
      end
    end
  rescue Errno::ESRCH
    raise ArgumentError, "package archive reader exited unexpectedly"
  end
end
