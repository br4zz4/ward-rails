require "test_helper"
require "ward/loader"

class LoaderTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("ward-loader")
    @config = Ward::Configuration.new
    @config.dir = @dir
    @config.bin = WardTest::FAKE_WARD
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def loader
    Ward::Loader.new(@config)
  end

  def with_env(values)
    saved = ENV.to_h
    values.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    ENV.replace(saved)
  end

  def test_secrets_parses_json_object
    assert_equal({ "RESEND_API_KEY" => "fake-value-123" }, loader.secrets("secrets.main.code.production"))
  end

  def test_value_parses_path_and_value
    assert_equal "fake-value-123", loader.value("main:secrets.main.code.production.RESEND_API_KEY")
  end

  def test_non_zero_exit_raises_load_failed
    with_env("FAKE_WARD_STATUS" => "2", "FAKE_WARD_STDERR" => "fake ward failure") do
      assert_raises(Ward::LoadFailed) { loader.secrets("secrets.main.code.production") }
    end
  end

  def test_missing_key_maps_to_key_unavailable_naming_env_var
    stderr = "missing key for vault commons — 1 file(s) skipped — set WARD_KEY_COMMONS to the contents of your age key"

    with_env("FAKE_WARD_STATUS" => "2", "FAKE_WARD_STDERR" => stderr) do
      error = assert_raises(Ward::KeyUnavailable) { loader.secrets("secrets.commons.code.production") }

      assert_includes error.message, "commons"
      assert_includes error.message, "WARD_KEY_COMMONS"
    end
  end

  def test_invalid_stdout_raises_load_failed_without_echoing_stdout
    with_env("FAKE_WARD_STDOUT" => "{not json") do
      error = assert_raises(Ward::LoadFailed) { loader.secrets("secrets.main.code.production") }

      refute_includes error.message, "{not json"
    end
  end

  def test_empty_object_raises_load_failed
    with_env("FAKE_WARD_STDOUT" => "{}") do
      assert_raises(Ward::LoadFailed) { loader.secrets("secrets.main.code.production") }
    end
  end

  def test_keys_hash_injects_string_symbol_and_proc_into_subprocess_env
    dump = File.join(@dir, "ward-key-env")
    @config.keys = {
      "main" => "string-key",
      "commons" => :WARD_KEY_SOURCE,
      "extra" => -> { "proc-key" }
    }

    with_env("WARD_KEY_SOURCE" => "symbol-key", "FAKE_WARD_ENV_DUMP" => dump) do
      loader.secrets("secrets.main.code.production")
    end

    received = File.readlines(dump, chomp: true).to_h { |line| line.split("=", 2) }
    assert_equal "string-key", received["WARD_KEY_MAIN"]
    assert_equal "symbol-key", received["WARD_KEY_COMMONS"]
    assert_equal "proc-key", received["WARD_KEY_EXTRA"]
    refute ENV.key?("WARD_KEY_MAIN")
    refute ENV.key?("WARD_KEY_EXTRA")
  end

  def test_missing_binary_raises_binary_not_found
    @config.bin = File.join(@dir, "nao-existe")

    error = assert_raises(Ward::BinaryNotFound) { loader.secrets("secrets.main.code.production") }

    assert_includes error.message, "ward:install"
    assert_includes error.message, "nao-existe"
  end

  def test_foreign_binary_magic_raises_binary_mismatch
    @config.bin = write_binary("ward-foreign", foreign_magic + "not-my-os")

    error = assert_raises(Ward::BinaryMismatch) { loader.secrets("secrets.main.code.production") }

    assert_includes error.message, RUBY_PLATFORM
    assert_includes error.message, "ward:install"
  end

  def test_shebang_binary_is_accepted
    @config.bin = write_binary(
      "ward-script", "#!/bin/sh\nprintf '%s' '{\"RESEND_API_KEY\":\"script-value\"}'\n"
    )

    assert_equal({ "RESEND_API_KEY" => "script-value" }, loader.secrets("secrets.main.code.production"))
  end

  def write_binary(name, content)
    path = File.join(@dir, name)
    File.binwrite(path, content)
    File.chmod(0o755, path)
    path
  end

  def foreign_magic
    RUBY_PLATFORM.match?(/darwin/) ? "\x7FELF".b : "\xFE\xED\xFA\xCF".b
  end
end
