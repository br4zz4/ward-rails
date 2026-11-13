require "test_helper"

class StoreTest < Minitest::Test
  def setup
    @store = Ward::Store.new(
      "RESEND_API_KEY" => "fake-value-123",
      "OTHER_KEY" => "fake-value-456"
    )
  end

  def teardown
    Ward.reset!
  end

  def test_brackets_return_value_for_string_and_symbol_names
    assert_equal "fake-value-123", @store["RESEND_API_KEY"]
    assert_equal "fake-value-123", @store[:RESEND_API_KEY]
  end

  def test_brackets_return_nil_for_absent_key
    assert_nil @store["NAO_EXISTE"]
    assert_nil @store[:NAO_EXISTE]
  end

  def test_fetch_raises_missing_secret_listing_key_names
    error = assert_raises(Ward::MissingSecret) { @store.fetch("NAO_EXISTE") }

    assert_includes error.message, "NAO_EXISTE"
    assert_includes error.message, "RESEND_API_KEY"
    assert_includes error.message, "OTHER_KEY"
    refute_includes error.message, "fake-value-123"
  end

  def test_fetch_returns_value_when_present
    assert_equal "fake-value-123", @store.fetch("RESEND_API_KEY")
  end

  def test_secrets_method_style_reads_store
    Ward.reset!
    Ward.store.replace!("resend_api_key" => "fake-value-123")

    assert_equal "fake-value-123", Ward.secrets.resend_api_key
    assert_same Ward.store, Ward.secrets
  end

  def test_values_are_frozen
    assert_predicate @store["RESEND_API_KEY"], :frozen?
    assert_raises(FrozenError) { @store["RESEND_API_KEY"] << "x" }
  end

  def test_inspect_shows_keys_but_never_values
    text = @store.inspect

    assert_includes text, "RESEND_API_KEY"
    assert_includes text, "OTHER_KEY"
    refute_includes text, "fake-value-123"
    refute_includes text, "fake-value-456"
    assert_equal text, @store.to_s
  end

  def test_unknown_method_raises_no_method_error
    assert_raises(NoMethodError) { @store.nao_existe }
  end

  def test_respond_to_missing_for_known_keys
    store = Ward::Store.new("resend_api_key" => "fake-value-123")

    assert_respond_to store, :resend_api_key
    refute_respond_to store, :nao_existe
  end
end
