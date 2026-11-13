require "test_helper"
require "rails"
require "ward/railtie"

class RailtieTest < Minitest::Test
  def app
    self.class.app
  end

  def self.app
    @app ||= boot_dummy
  end

  def self.boot_dummy
    saved = ENV.to_h
    ENV["WARD_ON_ERROR"] = "warn"
    ENV.delete("WARD_PROJECT_DIR")
    ENV.delete("WARD_GEM_BIN")
    ENV.delete("WARD_CONTEXT")
    require WardTest::DUMMY_ENV
    Rails.application
  ensure
    ENV.replace(saved)
  end

  def test_config_ward_is_exposed_on_the_application
    assert_instance_of Ward::Configuration, app.config.ward
  end

  def test_config_ward_dir_defaults_to_rails_root
    assert_equal app.root.to_s, app.config.ward.dir.to_s
  end

  def test_ward_configuration_is_the_application_config_object
    assert_same app.config.ward, Ward.configuration
  end
end
