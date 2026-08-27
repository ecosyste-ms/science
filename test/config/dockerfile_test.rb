require "test_helper"

class DockerfileTest < ActiveSupport::TestCase
  test "installs the Brief release with clone retries" do
    dockerfile = Rails.root.join("Dockerfile").read

    assert_includes dockerfile, "ARG BRIEF_VERSION=0.12.1"
  end
end
