module Ward
  class Configuration
    attr_accessor :context, :keys, :bin, :on_error, :dir

    def initialize
      @context = nil
      @keys = nil
      @bin = nil
      @on_error = :raise
      @dir = nil
    end

    def on_error=(value)
      unless %i[raise warn].include?(value)
        raise ArgumentError, "on_error must be :raise or :warn (got #{value.inspect})"
      end

      @on_error = value
    end
  end
end
