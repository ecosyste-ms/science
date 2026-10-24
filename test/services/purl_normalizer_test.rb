require "test_helper"

class PurlNormalizerTest < ActiveSupport::TestCase
  test "drops version and subpath" do
    assert_equal "pkg:pypi/numpy", PurlNormalizer.normalize("pkg:pypi/numpy@2.0#src")
  end

  test "drops the julia uuid qualifier" do
    assert_equal "pkg:julia/Dates",
      PurlNormalizer.normalize("pkg:julia/Dates@1.9.0?uuid=ade2ca70-3891-5945-98fb-dc099432e06a")
    assert_equal "pkg:julia/Dates?repository_url=https://example.org",
      PurlNormalizer.normalize("pkg:julia/Dates?repository_url=https://example.org&uuid=ade2ca70-3891-5945-98fb-dc099432e06a")
  end

  test "keeps qualifiers for other types" do
    assert_equal "pkg:deb/debian/curl?arch=amd64", PurlNormalizer.normalize("pkg:deb/debian/curl@7.0?arch=amd64")
  end
end
