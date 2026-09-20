require "test_helper"
require "tmpdir"

class SwhidCalculatorTest < ActiveSupport::TestCase
  test "calculates file content through stdin" do
    Tempfile.create("swhid-content") do |file|
      file.write("hello\n")
      file.flush
      result = SwhidCalculator.new.calculate(type: "content", path: file.path)
      assert_equal "swh:1:cnt:ce013625030ba8dba906f756967f9e9ca394464a", result["swhid"]
      assert_equal Digest::SHA256.hexdigest("hello\n"), result.dig("input", "sha256")
    end
  end

  test "missing executable is a recorded failure" do
    result = SwhidCalculator.new(binary: "/missing/swhid").calculate(type: "directory", path: ".")
    assert_equal "error", result["status"]
    assert_includes result["error"], "No such file"
    assert result["attempted_at"]
    assert result["duration_ms"]
  end

  test "malformed and wrong-type output cannot become a successful result" do
    ["not json", "[]", { swhid: "swh:1:cnt:#{'a' * 40}" }.to_json].each do |output|
      calculator = SwhidCalculator.new
      calculator.expects(:run).with(["swhid", "--version"]).returns("swhid v0.1.0\n")
      calculator.expects(:run).with(["swhid", "directory", "--format", "json", File.expand_path(".")]).returns(output)
      result = calculator.calculate(type: "directory", path: ".")
      assert_equal "error", result["status"]
      assert_nil result["swhid"]
    end
  end

  test "timeout terminates and reaps the subprocess" do
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 60", pgroup: true)
    Process.expects(:spawn).returns(pid)

    result = SwhidCalculator.new(timeout: 0.5).calculate(type: "directory", path: ".")

    assert_equal "error", result["status"]
    assert_includes result["error"], "timed out"
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    assert_raises(Errno::ECHILD) { Process.wait(pid) }
  ensure
    if pid
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
  end

  test "directory results retain the source artifact digest separately" do
    Dir.mktmpdir do |directory|
      artifact = File.join(directory, "source.tar.gz")
      File.binwrite(artifact, "artifact bytes\x00")
      extracted = File.join(directory, "extracted")
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "hello.txt"), "hello\n")
      result = SwhidCalculator.new.calculate(type: "directory", path: extracted, artifact: artifact)
      assert_equal "success", result["status"]
      assert_equal Digest::SHA256.file(artifact).hexdigest, result.dig("input", "artifact_sha256")
      assert_match(/\Aswh:1:dir:/, result["swhid"])
    end
  end

  test "bounds stderr and records a nonzero exit" do
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "failed-swhid")
      File.write(executable, "#!#{RbConfig.ruby}\nSTDERR.write('x' * 1000)\nexit 2\n")
      File.chmod(0755, executable)
      result = SwhidCalculator.new(binary: executable).calculate(type: "directory", path: directory)
      assert_equal "error", result["status"]
      assert_includes result["error"], "exit 2"
      assert_operator result["error"].length, :<=, 500
    end
  end
end
