require "test_helper"

class DockerfileTest < ActiveSupport::TestCase
  test "Docker and CI install the same Brief release" do
    dockerfile = Rails.root.join("Dockerfile").read
    ci = Rails.root.join(".github/workflows/ci.yml").read

    assert_includes dockerfile, "ARG BRIEF_VERSION=0.14.0"
    assert_includes ci, "https://github.com/git-pkgs/brief/releases/download/v0.14.0/brief_0.14.0_linux_amd64.tar.gz"
  end
end
