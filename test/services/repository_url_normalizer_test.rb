require "test_helper"

class RepositoryUrlNormalizerTest < ActiveSupport::TestCase
  test "normalizes common Git repository URLs" do
    assert_equal "https://github.com/numpy/numpy",
      RepositoryUrlNormalizer.normalize("git@github.com:NumPy/numpy.git")
    assert_equal "https://github.com/numpy/numpy",
      RepositoryUrlNormalizer.normalize(
        "git+https://github.com/NumPy/numpy/tree/main"
      )
    assert_equal "https://gitlab.example.org/group/project",
      RepositoryUrlNormalizer.normalize(
        "https://gitlab.example.org/group/project/-/blob/main/README.md"
      )
    assert_equal "https://bitbucket.org/team/project",
      RepositoryUrlNormalizer.normalize(
        "https://bitbucket.org/team/project/src/main/README.md"
      )
  end

  test "normalizes GitHub repository shorthand" do
    assert_equal "https://github.com/bazel-contrib/bazel-lib",
      RepositoryUrlNormalizer.normalize("github:bazel-contrib/bazel-lib")
    assert_equal "https://github.com/boostorg/program_options",
      RepositoryUrlNormalizer.normalize(" GITHUB:BoostOrg/program_options.git ")
    assert_equal "github.com",
      RepositoryUrlNormalizer.parse("github:google/boringssl").host
  end

  test "rejects malformed GitHub shorthand" do
    %w[
      github:owner
      github:/repo
      github:owner/
      github://owner/repo
      github:owner/repo/path
      github:owner/repo?query
      github:owner/repo#ref
      github:owner@host/repo
      github:../repo
    ].each do |value|
      assert_nil RepositoryUrlNormalizer.normalize(value), value
    end
  end

  test "rejects missing and malformed repository URLs" do
    assert_nil RepositoryUrlNormalizer.normalize(nil)
    assert_nil RepositoryUrlNormalizer.normalize("not a URL")
    assert_nil RepositoryUrlNormalizer.normalize("https://github.com/owner")
  end
end
