require "ward/version"
require "ward/errors"
require "ward/store"
require "ward/configuration"
require "ward/loader"

module Ward
  class << self
    attr_writer :configuration

    def configure
      yield configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def context
      configuration.context || ENV["WARD_CONTEXT"]
    end

    def store
      @store ||= Store.new
    end

    def boot!
      raise MissingContext, missing_context_message if context.to_s.strip.empty?

      Loader.new(configuration).verify_version!
      load!
      store
    rescue Error => error
      raise if configuration.on_error == :raise

      log_warning(error)
      @store = Store.new
      @booted = false
      store
    end

    def load!
      values = Loader.new(configuration).secrets(context)
      store.replace!(values)
      @booted = true
      store
    end

    def reload!
      boot!
    end

    def reset!
      @store = nil
      @booted = false
      @configuration = nil
    end

    def booted?
      @booted == true
    end

    def [](name)
      name = name.to_s
      return store[name] if store.key?(name)
      return nil unless name.include?(":")

      lazy_load(name)
    end

    def fetch(name)
      store.fetch(name)
    end

    def key?(name)
      store.key?(name)
    end

    def keys
      store.keys
    end

    def secrets
      store
    end

    private

    def lazy_load(path)
      lock.synchronize do
        return store[path] if store.key?(path)

        value = Loader.new(configuration).value(path)
        store.set!(path, value)
      end
    end

    def lock
      @lock ||= Mutex.new
    end

    def missing_context_message
      <<~MESSAGE
        WARD_CONTEXT is not set — the app cannot load its ward secrets.

        Set WARD_CONTEXT to the scope the app runs in, for example:
          WARD_CONTEXT=secrets.main.code.production

        Provide it as an environment variable for the app process, or set
        config.ward.context in config/initializers/ward.rb.
      MESSAGE
    end

    def log_warning(error)
      message = "ward: #{error.class}: #{error.message}"
      if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger.warn(message)
      else
        warn(message)
      end
    end
  end
end
