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

  test "rejects missing and malformed repository URLs" do
    assert_nil RepositoryUrlNormalizer.normalize(nil)
    assert_nil RepositoryUrlNormalizer.normalize("not a URL")
    assert_nil RepositoryUrlNormalizer.normalize("https://github.com/owner")
  end
end
