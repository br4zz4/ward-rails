require "open3"

require "ward/errors"
require "ward/loader"

module Ward
  # Prints the resolved ward setup and flags the usual adoption problems with an
  # actionable hint. Never prints secret values — only key names and counts.
  class Doctor
    def initialize(configuration)
      @configuration = configuration
    end

    def run(io = $stdout)
      problems = []

      io.puts "ward-rails doctor"
      io.puts "  ruby:        #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      io.puts "  context:     #{context_value}"
      io.puts "  project dir: #{@configuration.resolved_dir}"
      io.puts "  keys:        #{keys_summary}"

      loader = Loader.new(@configuration)

      begin
        path = loader.binary_path
        io.puts "  binary:      #{path} (#{binary_version(path)})"
      rescue Error => error
        problems << error
        io.puts "  binary:      ERROR #{error.class}: #{error.message}"
        io.puts "  hint:        #{hint(error)}"
      end

      if problems.empty?
        begin
          values = loader.secrets(Ward.context)
          io.puts "  scope:       #{values.size} key(s): #{values.keys.sort.join(", ")}"
        rescue Error => error
          problems << error
          io.puts "  scope:       ERROR #{error.class}: #{error.message}"
          io.puts "  hint:        #{hint(error)}"
        end
      end

      io.puts "  status:      #{problems.empty? ? "ok" : "problems found (#{problems.size})"}"
      problems.empty?
    end

    private

    def context_value
      value = Ward.context.to_s
      value.empty? ? "(missing) — set WARD_CONTEXT" : value
    end

    def keys_summary
      from_config = (@configuration.keys || {}).keys.sort
      from_env = ENV.keys.grep(/\AWARD_KEY_/).sort
      parts = []
      parts << "config=#{from_config.join(",")}" if from_config.any?
      parts << "env=#{from_env.join(",")}" if from_env.any?
      parts.empty? ? "(none configured — relying on the vault's own key files)" : parts.join(" ")
    end

    def binary_version(path)
      stdout, _stderr, status = Open3.capture3(path, "version")
      return "version unknown" unless status.success?

      stdout.to_s.strip
    rescue SystemCallError, IOError
      "version unknown"
    end

    def hint(error)
      case error
      when MissingContext
        "set WARD_CONTEXT to the scope the app runs in (e.g. secrets.<module>.code.<env>)"
      when BinaryNotFound
        "run `bin/rails ward:install` (or point WARD_EXECUTABLE_PATH at an existing ward)"
      when BinaryMismatch
        "bin/ward was installed for another OS/arch — run `bin/rails ward:install` on this host"
      when KeyUnavailable
        "provide the vault key via WARD_KEY_<VAULT> or config.ward.keys"
      when LoadFailed
        "check that the scope exists at that exact depth: `ward tree <scope>` in the project root"
      else
        "see docs/troubleshooting.md"
      end
    end
  end
end
