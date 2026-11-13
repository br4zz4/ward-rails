require "ward/errors"

module Ward
  # Holds the secrets for the app context. Values are duplicated and frozen;
  # inspect never reveals them.
  class Store
    def initialize(values = {})
      @values = {}
      replace!(values)
    end

    def [](name)
      @values[name.to_s]
    end

    def fetch(name)
      @values.fetch(name.to_s) do
        raise MissingSecret, "missing secret #{name.to_s.inspect}; available keys: #{sorted_keys.join(", ")}"
      end
    end

    def key?(name)
      @values.key?(name.to_s)
    end

    def keys
      @values.keys
    end

    def empty?
      @values.empty?
    end

    def set!(name, value)
      @values[name.to_s] = freeze_value(value) unless @values.key?(name.to_s)
      @values[name.to_s]
    end

    def replace!(values)
      @values = {}
      values.each { |name, value| @values[name.to_s] = freeze_value(value) }
      self
    end

    def inspect
      "#<Ward::Store keys=#{sorted_keys.inspect}>"
    end

    def to_s
      inspect
    end

    def respond_to_missing?(name, _include_private = false)
      @values.key?(name.to_s) || super
    end

    def method_missing(name, *args, &block)
      return @values[name.to_s] if args.empty? && @values.key?(name.to_s)

      super
    end

    private

    def freeze_value(value)
      value.to_s.dup.freeze
    end

    def sorted_keys
      keys.sort
    end
  end
end
