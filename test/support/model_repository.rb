require "tmpdir"

module ModelRepository
  def build_model_repository
    @repository_directory = Dir.mktmpdir("science-model-test-")
    @local_origin = "file://#{@repository_directory}"
    git("init", @repository_directory)
    File.write(File.join(@repository_directory, "README.md"), "# Model\n```bibtex\n@article{model, title={Research model}, doi={10.1234/model}}\n```\n")
    File.write(File.join(@repository_directory, "requirements.txt"), "numpy==2.0.0\n")
    File.write(File.join(@repository_directory, ".gitattributes"), "*.safetensors filter=lfs diff=lfs merge=lfs -text\n")
    File.write(File.join(@repository_directory, "model.safetensors"), "version https://git-lfs.github.com/spec/v1\noid sha256:#{'a' * 64}\nsize 10000000000\n")
    git("-C", @repository_directory, "add", ".")
    git("-C", @repository_directory, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Model")
    @revision = git("-C", @repository_directory, "rev-parse", "HEAD").strip
  end

  def git(*arguments)
    RepositoryCommand.new.run(["git", "-c", "filter.lfs.process=", "-c", "filter.lfs.smudge=", "-c", "filter.lfs.clean=", "-c", "filter.lfs.required=false", *arguments])
  end

  def use_local_model_checkout(origin, revision: @revision)
    @checkout_constructor ||= RepositoryCheckout.method(:new)
    checkout = @checkout_constructor.call(@local_origin, revision: revision, skip_lfs: true)
    RepositoryCheckout.expects(:new).with(origin, revision: revision, skip_lfs: true).returns(checkout)
  end
end
