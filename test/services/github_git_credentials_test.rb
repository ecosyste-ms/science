require "test_helper"
require "open3"
require "shellwords"

class GithubGitCredentialsTest < ActiveSupport::TestCase
  test "Git receives a token only for HTTPS GitHub credentials" do
    %w[github.com github.com:443].each do |host|
      output, _, status = credentials("https", host)
      assert status.success?
      assert_includes output, "username=x-access-token\n"
      assert_includes output, "password=github-test-token\n"
    end

    [["http", "github.com"], ["https", "gitlab.com"], ["https", "github.com.evil.test"], ["https", "github.com:8443"]].each do |protocol, host|
      output, _, status = credentials(protocol, host)
      refute status.success?
      refute_includes output, "github-test-token"
    end
  end

  test "Git receives no credentials without a token or with a multiline token" do
    [nil, "", "token\npassword=injected"].each do |token|
      output, _, status = credentials("https", "github.com", token: token)
      refute status.success?
      assert_empty output
    end
  end

  def credentials(protocol, host, token: "github-test-token")
    helper = "!#{Shellwords.join([RbConfig.ruby, Rails.root.join('bin/git-credential-github').to_s])}"
    env = { "GITHUB_TOKEN" => token, "GIT_TERMINAL_PROMPT" => "0", "GIT_ASKPASS" => "/bin/false",
      "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_COUNT" => "0" }
    Open3.capture3(env, "git", "-c", "credential.helper=", "-c", "credential.helper=#{helper}",
      "credential", "fill", stdin_data: "protocol=#{protocol}\nhost=#{host}\n\n")
  end
end
