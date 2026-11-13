require "test_helper"

class BootTest < Minitest::Test
  BOOT = <<~'RUBY'
    begin
      require ENV.fetch("DUMMY_ENV")
      puts "BOOT_OK"
      puts "VALUE=#{Ward["RESEND_API_KEY"].inspect}"
      puts "EMPTY=#{Ward.secrets.empty?}"
      puts "ENV_HAS_VALUE=#{ENV.key?("RESEND_API_KEY")}"
      puts "ENV_HAS_KEY=#{ENV.keys.grep(/\AWARD_KEY_/).empty?}"
    rescue Exception => error
      warn "#{error.class}: #{error.message}"
      exit 1
    end
  RUBY

  LAZY = <<~'RUBY'
    require ENV.fetch("DUMMY_ENV")
    first = Ward["main:secrets.main.code.production.OUTRA"]
    second = Ward["main:secrets.main.code.production.OUTRA"]
    puts "FIRST=#{first.inspect}"
    puts "SECOND=#{second.inspect}"
  RUBY

  RELOAD = <<~'RUBY'
    require ENV.fetch("DUMMY_ENV")
    before = Ward["RESEND_API_KEY"]
    system(
      ENV.fetch("WARD_BIN"), "-d", ENV.fetch("WARD_PROJECT_DIR"),
      "set", "main:secrets.main.code.production.RESEND_API_KEY", ENV.fetch("NEW_VALUE"),
      out: File::NULL, err: File::NULL
    )
    Ward.reload!
    after = Ward["RESEND_API_KEY"]
    puts "BEFORE=#{before.inspect}"
    puts "AFTER=#{after.inspect}"
  RUBY

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  def base_env(project)
    {
      "DUMMY_ENV" => WardTest::DUMMY_ENV,
      "WARD_BIN" => WardTest.ward_bin,
      "WARD_PROJECT_DIR" => project,
      "WARD_AI_MODE" => "0",
      "WARD_ON_ERROR" => "raise"
    }
  end

  def run_boot(env, script = BOOT)
    WardTest.run_ruby(env, script)
  end

  def test_boot_loads_context_without_writing_env
    project = WardTest.create_project(WardTest.default_secrets)

    stdout, stderr, status = run_boot(base_env(project).merge("WARD_CONTEXT" => "secrets.main.code.production"))

    assert status.success?, stderr
    assert_includes stdout, "BOOT_OK"
    assert_includes stdout, 'VALUE="fake-value-123"'
    assert_includes stdout, "ENV_HAS_VALUE=false"
    assert_includes stdout, "ENV_HAS_KEY=true"
  end

  def test_missing_context_fails_with_example
    project = WardTest.create_project(WardTest.default_secrets)

    _stdout, stderr, status = run_boot(base_env(project))

    refute status.success?
    assert_includes stderr, "Ward::MissingContext"
    assert_includes stderr, "secrets.main.code.production"
  end

  def test_missing_binary_points_at_ward_install
    project = WardTest.create_project(WardTest.default_secrets)
    env = base_env(project).merge(
      "WARD_CONTEXT" => "secrets.main.code.production",
      "WARD_GEM_BIN" => File.join(project, "bin", "nao-existe")
    )

    _stdout, stderr, status = run_boot(env)

    refute status.success?
    assert_includes stderr, "Ward::BinaryNotFound"
    assert_includes stderr, "ward:install"
  end

  def test_locked_vault_raises_naming_vault_and_key
    project = WardTest.add_locked_vault(WardTest.create_project(WardTest.default_secrets))

    _stdout, stderr, status = run_boot(base_env(project).merge("WARD_CONTEXT" => "secrets.commons.code.production"))

    refute status.success?
    assert_includes stderr, "commons"
    assert_includes stderr, "WARD_KEY_COMMONS"
    assert_match(/Ward::(KeyUnavailable|LoadFailed)/, stderr)
  end

  def test_on_error_warn_boots_with_empty_store
    project = WardTest.add_locked_vault(WardTest.create_project(WardTest.default_secrets))
    env = base_env(project).merge(
      "WARD_CONTEXT" => "secrets.commons.code.production",
      "WARD_ON_ERROR" => "warn",
      "WARD_LOG_STDERR" => "1"
    )

    stdout, stderr, status = run_boot(env)

    assert status.success?, stderr
    assert_includes stdout, "EMPTY=true"
    assert_includes stderr, "WARD_KEY_COMMONS"
  end

  def test_qualified_lazy_read_is_memoized
    project = WardTest.create_project(WardTest.default_secrets)
    @tmp = Dir.mktmpdir("ward-boot-wrapper")
    log = File.join(@tmp, "calls.log")
    wrapper = File.join(@tmp, "ward-wrapper")
    File.write(wrapper, <<~SH)
      #!/bin/sh
      printf 'call\n' >> "#{log}"
      exec "#{WardTest.ward_bin}" "$@"
    SH
    FileUtils.chmod(0o755, wrapper)
    env = base_env(project).merge(
      "WARD_CONTEXT" => "secrets.main.code.production",
      "WARD_BIN" => wrapper
    )

    stdout, stderr, status = run_boot(env, LAZY)

    assert status.success?, stderr
    assert_includes stdout, 'FIRST="other-value-456"'
    assert_includes stdout, 'SECOND="other-value-456"'
    assert_equal 2, File.readlines(log).size
  end

  def test_reload_rereads_value_after_set
    project = WardTest.create_project(WardTest.default_secrets)
    env = base_env(project).merge(
      "WARD_CONTEXT" => "secrets.main.code.production",
      "NEW_VALUE" => "fake-value-456"
    )

    stdout, stderr, status = run_boot(env, RELOAD)

    assert status.success?, stderr
    assert_includes stdout, 'BEFORE="fake-value-123"'
    assert_includes stdout, 'AFTER="fake-value-456"'
  end
end
