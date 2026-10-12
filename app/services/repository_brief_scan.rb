class RepositoryBriefScan
  def self.call(checkout)
    output = RepositoryCommand.new(timeout: 120, output_limit: 10.megabytes).run(["brief", "-json", checkout])
    data = JSON.parse(output)
    raise JSON::ParserError, "Expected a Brief JSON object" unless data.is_a?(Hash)

    %w[version languages package_managers tools resources manifests dependencies lines].index_with { |key| data[key] }
  end
end
