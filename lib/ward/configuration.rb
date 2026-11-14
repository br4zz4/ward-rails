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

    # The ward project directory (passed to the CLI as -d). Precedence:
    # explicit config → WARD_DIR env → Rails.root → current directory.
    def resolved_dir
      dir || ENV["WARD_DIR"] || rails_root || Dir.pwd
    end

    private

    def rails_root
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:root)

      root = ::Rails.root
      root.nil? || root.to_s.empty? ? nil : root
    end
  end
end
