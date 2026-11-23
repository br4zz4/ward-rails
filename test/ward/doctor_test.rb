require "test_helper"
require "stringio"
require "ward/doctor"

class DoctorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("ward-doctor")
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
    Ward.reset!
  end

  def configure(bin: WardTest::FAKE_WARD)
    Ward.configure do |config|
      config.bin = bin
      config.dir = @dir
    end
  end

  def run_doctor(env = {})
    io = StringIO.new

    with_env({ "WARD_CONTEXT" => "secrets.main.code.production" }.merge(env)) do
      @result = Ward::Doctor.new(Ward.configuration).run(io)
    end

    io.string
  end

  def test_happy_path_reports_ok_and_key_names_without_values
    # arrange
    configure

    # act
    output = run_doctor

    # assert
    assert @result
    assert_includes output, "status:      ok"
    assert_includes output, "RESEND_API_KEY"
    refute_includes output, "fake-value-123"
  end

  def test_missing_context_reports_missing_context_and_hint
    # arrange
    configure
    io = StringIO.new

    # act
    with_env("WARD_CONTEXT" => nil) do
      @result = Ward::Doctor.new(Ward.configuration).run(io)
    end

    # assert
    refute @result
    assert_includes io.string, "(missing)"
    assert_includes io.string, "MissingContext"
    assert_includes io.string, "WARD_CONTEXT"
  end

  def test_missing_binary_reports_binary_not_found_and_install_hint
    # arrange
    configure(bin: File.join(@dir, "nao-existe"))

    # act
    output = run_doctor

    # assert
    refute @result
    assert_includes output, "BinaryNotFound"
    assert_includes output, "ward:install"
  end

  def test_outdated_binary_reports_binary_outdated_and_upgrade_hint
    # arrange
    configure

    # act
    output = run_doctor("FAKE_WARD_VERSION" => "0.3.2")

    # assert
    refute @result
    assert_includes output, "BinaryOutdated"
    assert_includes output, "upgrade ward"
    assert_includes output, ">= #{Ward::WARD_MIN_VERSION}"
  end

  def test_rake_lists_ward_doctor_task
    # act
    stdout, stderr, status = Open3.capture3("bundle", "exec", "rake", "-T", chdir: WardTest::ROOT)

    # assert
    assert status.success?, stderr
    assert_includes stdout, "ward:doctor"
  end

  def test_rake_doctor_exits_non_zero_without_context
    # act
    _stdout, _stderr, status = Open3.capture3(
      { "WARD_CONTEXT" => nil }, "bundle", "exec", "rake", "ward:doctor", chdir: WardTest::ROOT
    )

    # assert
    refute status.success?
  end
end
