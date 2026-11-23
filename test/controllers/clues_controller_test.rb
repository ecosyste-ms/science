require "test_helper"

class CluesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @settings = ENV.to_h.slice("CLUE_EXPORT_BUCKET", "AWS_REGION")
    ENV["CLUE_EXPORT_BUCKET"] = "science-clue-demo"
    ENV["AWS_REGION"] = "eu-west-2"
    @latest = "https://science-clue-demo.s3.eu-west-2.amazonaws.com/clues/latest.json"
  end

  teardown do
    %w[CLUE_EXPORT_BUCKET AWS_REGION].each { |key| ENV[key] = @settings[key] }
  end

  test "renders the permanent download link without contacting S3" do
    get clues_path

    assert_response :success
    assert_select "nav a[href=?]", clues_path, text: "Clues"
    assert_select "main h1", "Software clues"
    assert_select "main a.btn-primary[href=?]", @latest, text: "Download"
    assert_select "main a", count: 1
    assert_not_requested :any, %r{amazonaws\.com}
  end

  test "explains clues without download settings" do
    %w[CLUE_EXPORT_BUCKET AWS_REGION].each do |key|
      value = ENV.delete(key)
      get clues_path
      assert_response :success
      assert_select "main code", "ZOSPy"
      assert_select "main a", count: 0
      ENV[key] = value
    end
  end
end
