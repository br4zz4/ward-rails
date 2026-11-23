require "test_helper"

class OptionalContextTest < Minitest::Test
  CONTEXT = "secrets.main.code.production".freeze

  def setup
    Ward.reset!
  end

  def teardown
    Ward.reset!
  end

  def capture_stderr
    messages = []
    original = Ward.method(:log_warning)
    Ward.singleton_class.send(:define_method, :log_warning) { |error| messages << "ward: #{error.class}: #{error.message}" }
    yield
    messages.join("\n")
  ensure
    Ward.singleton_class.send(:define_method, :log_warning, original)
  end

  def configure(optional:, on_error:, context: nil, project: nil)
    Ward.configure do |config|
      config.optional = optional
      config.on_error = on_error
      config.context = context
      config.bin = WardTest.ward_bin
      config.dir = project
    end
  end

  def test_default_configuration_is_not_optional
    # arrange
    config = Ward::Configuration.new

    # act
    optional = config.optional

    # assert
    assert_equal false, optional
  end

  def test_optional_without_context_does_not_raise_nor_log_on_error_raise
    # arrange
    configure(optional: true, on_error: :raise)

    with_env("WARD_CONTEXT" => nil) do
      # act
      stderr = capture_stderr { Ward.boot! }

      # assert
      assert_equal "", stderr
      refute_predicate Ward, :booted?
      assert_empty Ward.secrets.keys
    end
  end

  def test_optional_without_context_does_not_raise_nor_log_on_error_warn
    # arrange
    configure(optional: true, on_error: :warn)

    with_env("WARD_CONTEXT" => nil) do
      # act
      stderr = capture_stderr { Ward.boot! }

      # assert
      assert_equal "", stderr
      refute_predicate Ward, :booted?
      assert_empty Ward.secrets.keys
    end
  end

  def test_optional_without_context_returns_empty_store
    # arrange
    configure(optional: true, on_error: :raise)

    with_env("WARD_CONTEXT" => nil) do
      # act
      store = Ward.boot!

      # assert
      assert_same Ward.store, store
      assert_empty store.keys
    end
  end

  def test_lookup_returns_nil_when_optional_without_context
    # arrange
    configure(optional: true, on_error: :raise)

    with_env("WARD_CONTEXT" => nil) do
      Ward.boot!

      # act
      value = Ward["RESEND_API_KEY"]

      # assert
      assert_nil value
    end
  end

  def test_optional_with_blank_context_is_treated_as_missing
    # arrange
    configure(optional: true, on_error: :raise)

    with_env("WARD_CONTEXT" => "   ") do
      # act
      stderr = capture_stderr { Ward.boot! }

      # assert
      assert_equal "", stderr
      refute_predicate Ward, :booted?
    end
  end

  def test_optional_with_context_from_config_still_loads
    # arrange
    project = WardTest.create_project(WardTest.default_secrets)
    configure(optional: true, on_error: :raise, context: CONTEXT, project: project)

    with_env("WARD_CONTEXT" => nil, "WARD_AI_MODE" => "0") do
      # act
      Ward.boot!

      # assert
      assert_predicate Ward, :booted?
      assert_equal "fake-value-123", Ward["RESEND_API_KEY"]
    end
  end

  def test_optional_with_context_from_env_still_loads
    # arrange
    project = WardTest.create_project(WardTest.default_secrets)
    configure(optional: true, on_error: :raise, project: project)

    with_env("WARD_CONTEXT" => CONTEXT, "WARD_AI_MODE" => "0") do
      # act
      Ward.boot!

      # assert
      assert_predicate Ward, :booted?
      assert_equal "other-value-456", Ward["OUTRA"]
    end
  end

  def test_optional_with_context_still_raises_load_errors_on_error_raise
    # arrange
    project = WardTest.add_locked_vault(WardTest.create_project(WardTest.default_secrets))
    configure(optional: true, on_error: :raise, context: "secrets.commons.code.production", project: project)

    with_env("WARD_AI_MODE" => "0", "WARD_KEY_COMMONS" => nil) do
      # act
      error = assert_raises(Ward::Error) { Ward.boot! }

      # assert
      assert_includes error.message, "WARD_KEY_COMMONS"
    end
  end

  def test_optional_with_context_still_warns_load_errors_on_error_warn
    # arrange
    project = WardTest.add_locked_vault(WardTest.create_project(WardTest.default_secrets))
    configure(optional: true, on_error: :warn, context: "secrets.commons.code.production", project: project)

    with_env("WARD_AI_MODE" => "0", "WARD_KEY_COMMONS" => nil) do
      # act
      stderr = capture_stderr { Ward.boot! }

      # assert
      assert_includes stderr, "WARD_KEY_COMMONS"
      refute_predicate Ward, :booted?
    end
  end

  def test_not_optional_without_context_raises_missing_context
    # arrange
    configure(optional: false, on_error: :raise)

    with_env("WARD_CONTEXT" => nil) do
      # act
      error = assert_raises(Ward::MissingContext) { Ward.boot! }

      # assert
      assert_includes error.message, CONTEXT
    end
  end

  def test_not_optional_without_context_warns_on_error_warn
    # arrange
    configure(optional: false, on_error: :warn)

    with_env("WARD_CONTEXT" => nil) do
      # act
      stderr = capture_stderr { Ward.boot! }

      # assert
      assert_includes stderr, "Ward::MissingContext"
      refute_predicate Ward, :booted?
    end
  end
end
