require "csv"
require "digest/md5"
require "json"
require "open3"
require "public_suffix"
require "tempfile"

class RorResearchOrganizationDomainImporter
  ZENODO_RECORD_URL = "https://zenodo.org/api/records/6347574"
  MINIMUM_DOMAINS = 10_000
  FULL_STRENGTH_TYPES = %w[education government facility nonprofit healthcare archive].freeze

  class << self
    def sync!(minimum_domains: MINIMUM_DOMAINS)
      metadata = fetch_metadata
      version = metadata.fetch("id").to_s
      if ResearchOrganizationDomain.active_version_for("ror") == version
        ResearchOrganizationDomain.prune_inactive!("ror")
        return {
          source: "ror",
          version: version,
          domains: ResearchOrganizationDomain.active.where(source: "ror").count,
          published_at: ResearchOrganizationDomain.active.where(source: "ror").pick(:published_at),
          imported: false,
        }
      end

      file = metadata.fetch("files").find { |candidate| candidate.fetch("key").end_with?(".zip") }
      raise "ROR release does not contain a ZIP file" unless file

      Tempfile.create(["ror-data", ".zip"]) do |archive|
        archive.binmode
        download_archive(file.fetch("links").fetch("self"), archive)
        verify_checksum!(archive.path, file.fetch("checksum"))
        archive.flush

        open_csv(archive.path) do |csv|
          return import_csv!(
            csv,
            version: version,
            published_at: metadata.dig("metadata", "publication_date"),
            minimum_domains: minimum_domains,
            metadata: {
              "record_id" => metadata.fetch("id"),
              "doi" => metadata.fetch("doi"),
              "filename" => file.fetch("key"),
              "checksum" => file.fetch("checksum"),
            }
          )
        end
      end
    end

    def import_csv!(csv, version:, published_at:, metadata: {}, minimum_domains: MINIMUM_DOMAINS)
      version = version.to_s
      if ResearchOrganizationDomain.active_version_for("ror") == version
        ResearchOrganizationDomain.prune_inactive!("ror")
        return {
          source: "ror",
          version: version,
          domains: ResearchOrganizationDomain.active.where(source: "ror").count,
          published_at: ResearchOrganizationDomain.active.where(source: "ror").pick(:published_at),
          imported: false,
        }
      end

      ResearchOrganizationDomain.where(source: "ror", source_version: version, active: false).delete_all
      counts = import_rows!(csv, version: version, published_at: published_at)
      counts[:domains] = ResearchOrganizationDomain.where(source: "ror", source_version: version).count
      if counts.fetch(:domains) < minimum_domains
        raise "ROR import contained only #{counts.fetch(:domains)} valid domains"
      end

      ResearchOrganizationDomain.activate_version!(source: "ror", version: version)
      {
        source: "ror",
        version: version,
        published_at: published_at,
        imported: true,
      }.merge(metadata).merge(counts)
    rescue StandardError
      ResearchOrganizationDomain.where(source: "ror", source_version: version, active: false).delete_all if version
      raise
    end

    def fetch_metadata
      response = connection.get(ZENODO_RECORD_URL)
      raise "Zenodo metadata request failed with HTTP #{response.status}" unless response.success?

      JSON.parse(response.body)
    end

    def download_archive(url, output)
      response = connection.get(url)
      raise "ROR download failed with HTTP #{response.status}" unless response.success?

      output.write(response.body)
      output.flush
    end

    def verify_checksum!(path, checksum)
      algorithm, expected = checksum.split(":", 2)
      raise "Unsupported ROR checksum algorithm: #{algorithm}" unless algorithm == "md5"

      actual = Digest::MD5.file(path).hexdigest
      raise "ROR checksum mismatch: expected #{expected}, got #{actual}" unless actual == expected
    end

    def open_csv(path)
      listing, error, status = Open3.capture3("bsdtar", "-tf", path)
      raise "Could not inspect ROR archive: #{error.strip}" unless status.success?

      csv_name = listing.lines.map(&:strip).find { |name| name.end_with?(".csv") }
      raise "ROR archive does not contain a CSV file" unless csv_name

      Open3.popen3("bsdtar", "-xOf", path, csv_name) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        error_reader = Thread.new { stderr.read }
        result = yield stdout
        status = wait_thread.value
        error = error_reader.value
        raise "Could not extract ROR CSV: #{error.strip}" unless status.success?
        result
      end
    end

    def import_rows!(csv, version:, published_at:)
      counts = { records: 0, domains: 0, rejected_public_suffixes: 0 }
      rows = []
      now = Time.current

      CSV.new(csv, headers: true).each do |row|
        next unless row["status"] == "active"

        counts[:records] += 1
        types = split_values(row["types"])
        split_values(row["domains"]).each do |domain|
          normalized = ResearchOrganizationDomainMatcher.normalize_domain(domain)
          next unless normalized
          unless PublicSuffix.valid?(normalized)
            counts[:rejected_public_suffixes] += 1
            next
          end

          rows << {
            domain: normalized,
            source: "ror",
            source_version: version,
            published_at: published_at,
            active: false,
            external_id: row.fetch("id"),
            organization_name: row["names.types.ror_display"],
            organization_types: types,
            strength: (types & FULL_STRENGTH_TYPES).any? ? 1.0 : 0.4,
            created_at: now,
            updated_at: now,
          }
          counts[:domains] += 1
          flush_rows!(rows) if rows.length >= 1_000
        end
      end
      flush_rows!(rows)
      counts
    end

    def flush_rows!(rows)
      return if rows.empty?

      ResearchOrganizationDomain.insert_all(
        rows,
        unique_by: :index_research_domains_on_source_version_domain_id
      )
      rows.clear
    end

    def split_values(value)
      value.to_s.split(";").map(&:strip).reject(&:empty?)
    end

    def connection
      Faraday.new do |faraday|
        faraday.headers["User-Agent"] = "science.ecosyste.ms ROR importer"
        faraday.headers["Authorization"] = "Bearer #{ENV.fetch('ZENODO_API_KEY')}" if ENV["ZENODO_API_KEY"].present?
        faraday.request :instrumentation
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
    end
  end
end
