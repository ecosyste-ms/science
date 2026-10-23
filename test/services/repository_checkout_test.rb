require "test_helper"
require_relative "../support/model_repository"

class RepositoryCheckoutTest < ActiveSupport::TestCase
  include ModelRepository

  setup { build_model_repository }
  teardown { FileUtils.remove_entry(@repository_directory) }

  test "checks out an older pinned revision with weight pointers and removes the checkout" do
    original = File.read(File.join(@repository_directory, "README.md"))
    File.write(File.join(@repository_directory, "README.md"), "# Newer model\n")
    git("-C", @repository_directory, "add", ".")
    git("-C", @repository_directory, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Newer model")
    path = nil
    RepositoryCheckout.new(@local_origin, revision: @revision, skip_lfs: true).open do |checkout|
      path = checkout
      assert_equal @revision, git("-C", checkout, "rev-parse", "HEAD").strip
      assert_equal original, File.read(File.join(checkout, "README.md"))
      assert File.read(File.join(checkout, "model.safetensors")).start_with?("version https://git-lfs.github.com/spec/v1\n")
      assert_operator File.size(File.join(checkout, "model.safetensors")), :<, 1024
    end
    assert_not File.exist?(path)
  end

  test "disk cap applies to clones and cleanup runs on failure" do
    before = Dir.glob(File.join(Dir.tmpdir, "science-repository-*"))
    error = assert_raises(RepositoryCommand::Error) do
      RepositoryCheckout.new(@local_origin, disk_limit: 1).open { flunk "Oversized checkout was yielded" }
    end
    assert_includes error.message, "disk limit"
    assert_equal before, Dir.glob(File.join(Dir.tmpdir, "science-repository-*"))
  end

  test "partial checkouts leave large files on the server" do
    File.binwrite(File.join(@repository_directory, "data set [1].bin"), Random.bytes(2.megabytes))
    FileUtils.mkdir_p(File.join(@repository_directory, "src"))
    File.write(File.join(@repository_directory, "src", "main.py"), "print('hello')\n")
    git("-C", @repository_directory, "add", ".")
    git("-C", @repository_directory, "-c", "user.name=Test", "-c", "user.email=test@example.org", "-c", "commit.gpgsign=false", "commit", "-m", "Add data")
    git("-C", @repository_directory, "config", "uploadpack.allowFilter", "true")

    checkout_test = RepositoryCheckout.new("file://#{@repository_directory}", partial: true)
    checkout_test.open do |checkout|
      assert File.exist?(File.join(checkout, "src", "main.py"))
      assert File.exist?(File.join(checkout, "README.md"))
      assert_not File.exist?(File.join(checkout, "data set [1].bin"))
      assert_equal 1, git("-C", checkout, "rev-list", "--objects", "--missing=print", "HEAD").lines.count { |line| line.start_with?("?") }
    end
    assert_equal 1, checkout_test.skipped_paths
  end

  test "resource evidence refuses paths outside the checkout and LFS pointers" do
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "README.md"), "private")
      File.symlink(File.join(outside, "README.md"), File.join(@repository_directory, "linked.md"))
      ["../README.md", "/README.md", ".git/config", "linked.md", "model.safetensors"].each do |path|
        result = RepositoryResources.read(@repository_directory, path, url: "https://example.org/file")
        assert_equal "error", result["status"]
        assert_nil result["content"]
      end
    end
  end

  test "inherited credential helpers and askpass cannot open authentication prompts" do
    previous = ENV.to_h.slice("GIT_CONFIG_GLOBAL", "GIT_ASKPASS")
    marker = File.join(@repository_directory, "prompt-opened")
    helper = "!touch #{Shellwords.escape(marker)}"
    config = File.join(@repository_directory, "global-config")
    File.write(config, "[credential]\n\thelper = #{helper}\n[credential \"https://huggingface.co\"]\n\thelper = #{helper}\n")
    ENV["GIT_CONFIG_GLOBAL"] = config
    ENV["GIT_ASKPASS"] = "touch #{Shellwords.escape(marker)}"
    Tempfile.create("git-credentials") do |input|
      input.write("protocol=https\nhost=huggingface.co\n\n")
      input.rewind
      error = assert_raises(RepositoryCommand::Error) do
        RepositoryCommand.new.run(["git", *RepositoryCheckout.credentials("https://huggingface.co/example/model"), "credential", "fill"], input: input)
      end
      assert_includes error.message, "terminal prompts disabled"
      assert_not File.exist?(marker)
    end
  ensure
    %w[GIT_CONFIG_GLOBAL GIT_ASKPASS].each { |key| ENV[key] = previous[key] }
  end
end
