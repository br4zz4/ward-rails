require "rails"

class DummyApplication < Rails::Application
  config.load_defaults 8.0
  config.eager_load = false
  config.secret_key_base = "ward-rails-test-secret-key-base"
  config.logger = if ENV["WARD_LOG_STDERR"]
                    Logger.new($stderr)
                  else
                    Logger.new(File::NULL)
                  end
  config.ward.on_error = (ENV["WARD_ON_ERROR"] || "raise").to_sym
end
