class CluesController < ApplicationController
  def index
    bucket = ENV["CLUE_EXPORT_BUCKET"].presence
    region = ENV["AWS_REGION"].presence
    return unless bucket && region

    host = "s3.#{region}.amazonaws.com"
    base = bucket.include?(".") ? "https://#{host}/#{bucket}" : "https://#{bucket}.#{host}"
    @latest_url = "#{base}/#{SearchSeedParquetPublisher::LATEST_KEY}"
  end
end
