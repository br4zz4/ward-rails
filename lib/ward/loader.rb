require "json"
require "open3"

require "ward/errors"
require "ward/version"

module Ward
  # Runs the ward CLI as a subprocess and maps its JSON output to plain hashes.
  # Secret values never leave stdout: failure messages are built from the exit
  # status and a sanitized stderr only.
  class Loader
    ANSI = /\e\[[0-9;]*m/

    # Executable magic bytes used to refuse a binary installed for another OS.
    MACHO_MAGICS = [
      "\xFE\xED\xFA\xCE", "\xFE\xED\xFA\xCF",
      "\xCE\xFA\xED\xFE", "\xCF\xFA\xED\xFE",
      "\xCA\xFE\xBA\xBE", "\xBE\xBA\xFE\xCA"
    ].map(&:b).freeze
    ELF_MAGIC = "\x7FELF".b.freeze

    def initialize(configuration)
      @configuration = configuration
    end

    def secrets(scope)
      raise MissingContext, "no scope given — set WARD_CONTEXT" if scope.to_s.strip.empty?

      stdout, stderr, status = execute("secrets", scope)
      raise failure(stderr, scope) unless status.success?

      values = parse_object(stdout, scope)
      raise empty_scope_error(stderr, scope) if values.empty?

      values
    end

    def value(path)
      raise LoadFailed, "no secret path given" if path.to_s.strip.empty?

      stdout, stderr, status = execute("get", path)
      raise failure(stderr, path) unless status.success?

      parse_object(stdout, path).fetch("value")
    rescue KeyError, TypeError
      raise LoadFailed, "ward returned no value for #{path.inspect}"
    end

    def binary_path
      binary
    end

    # The installed ward must be new enough for the JSON contract this gem
    # relies on (secrets/get --json). Runs once at boot and on `ward:doctor`.
    def verify_version!
      path = binary_path
      stdout, _stderr, status = Open3.capture3(path, "version")
      raise BinaryMismatch, mismatch_message(path) unless status.success?

      match = stdout.to_s.match(/ward version (\d+\.\d+\.\d+)/)
      raise BinaryMismatch, mismatch_message(path) unless match

      installed = Gem::Version.new(match[1])
      required = Gem::Version.new(WARD_MIN_VERSION)
      return true if installed >= required

      raise BinaryOutdated,
            "ward #{installed} is installed at #{path}, but ward-rails requires >= #{required}. " \
            "Upgrade it (brew upgrade ward, your package manager, or `bin/rails ward:install`)."
    end

    private

    def execute(command, scope)
      Open3.capture3(key_env, *argv(command, scope))
    rescue Errno::ENOEXEC
      raise BinaryMismatch, mismatch_message
    rescue Errno::ENOENT
      raise BinaryNotFound, "ward binary could not be started at #{binary} — run bin/rails ward:install"
    end

    def argv(command, scope)
      [binary, "-d", @configuration.resolved_dir.to_s, "--raw", command, "--json", scope]
    end

    def key_env
      configured = @configuration.keys
      return {} if configured.nil?

      configured.each_with_object({}) do |(vault, source), env|
        value = resolve_key(source)
        env["WARD_KEY_#{vault.to_s.upcase}"] = value.to_s unless value.nil? || value.to_s.empty?
      end
    end

    def resolve_key(source)
      case source
      when Symbol then ENV[source.to_s]
      when Proc then source.call
      else source
      end
    end

    def empty_scope_error(stderr, scope)
      vault = missing_key_vault(stderr)
      return KeyUnavailable.new(missing_key_message(vault, scope, stderr)) if vault

      LoadFailed.new(
        "no secrets resolved for scope #{scope.inspect} — check that the scope path exists " \
        "in the vault (ward secrets --json #{scope})."
      )
    end

    def failure(stderr, scope)
      vault = missing_key_vault(stderr)
      return KeyUnavailable.new(missing_key_message(vault, scope, stderr)) if vault

      LoadFailed.new("ward failed reading #{scope.inspect}: #{summarize(stderr)}")
    end

    def missing_key_vault(stderr)
      stderr.to_s[/missing key for vault (\S+)/, 1]
    end

    def missing_key_message(vault, scope, stderr)
      "vault #{vault.inspect} is locked — provide #{key_env_name(vault)} (env var) or " \
        "config.ward.keys[#{vault.inspect}] to read #{scope.inspect}. Ward said: #{summarize(stderr)}"
    end

    # The binary exists and is executable but the OS refuses to run it — almost
    # always a binary installed for another platform (macOS asset in a Linux
    # image, or vice versa).
    def mismatch_message(path = nil)
      location = path ? " at #{path}" : ""
      "the ward binary#{location} cannot run on this host (#{RUBY_PLATFORM}) — it was " \
        "probably installed for a different OS/arch. Run bin/rails ward:install on this " \
        "platform (or during the image build); never commit or copy bin/ward across platforms."
    end

    def key_env_name(vault)
      "WARD_KEY_#{vault.upcase}"
    end

    def summarize(stderr)
      text = stderr.to_s.gsub(ANSI, "").strip
      first = text.lines.reject { |line| line.strip.empty? }.last.to_s.strip
      first = first[0, 400] if first.length > 400
      first.empty? ? "(no output)" : first
    end

    def parse_object(stdout, scope)
      parsed = JSON.parse(stdout.to_s)
      raise TypeError unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, TypeError
      raise LoadFailed, "ward returned an unexpected payload for #{scope.inspect}"
    end

    def binary
      configured = @configuration.bin || ENV["WARD_EXECUTABLE_PATH"]
      return verified!(resolve_explicit(configured)) if configured

      found = default_binary
      return verified!(found) if found

      raise BinaryNotFound,
            "ward binary not found (looked for #{default_candidates.join(" and ")}). " \
            "Run `bin/rails ward:install`, set WARD_EXECUTABLE_PATH to an existing ward, or " \
            "install ward via your package manager."
    end

    def verified!(path)
      verify_platform!(path)
      path
    end

    # Fails fast when bin/ward was built for another OS/arch (a macOS binary in
    # a Linux image, or the reverse): the OS would only surface it as an opaque
    # exec error.
    def verify_platform!(path)
      head = File.binread(path, 4).to_s.b
      return if head.empty? || head.start_with?("#!")

      case RUBY_PLATFORM
      when /darwin/
        raise BinaryMismatch, mismatch_message(path) unless MACHO_MAGICS.include?(head)
      when /linux/
        raise BinaryMismatch, mismatch_message(path) unless head == ELF_MAGIC
      end
    rescue Errno::ENOENT
      nil
    end

    def resolve_explicit(configured)
      path = configured.to_s
      return path if executable?(path)

      raise BinaryNotFound, "ward binary at #{path} is not executable — run `bin/rails ward:install` or fix WARD_EXECUTABLE_PATH."
    end

    def default_binary
      default_candidates.each do |candidate|
        return candidate if executable?(candidate)

        path = which(candidate)
        return path if path
      end
      nil
    end

    def default_candidates
      candidates = []
      candidates << File.join(@configuration.resolved_dir.to_s, "bin", "ward")
      candidates << "ward"
      candidates
    end

    def executable?(path)
      !path.to_s.empty? && File.file?(path.to_s) && File.executable?(path.to_s)
    end

    def which(name)
      return nil if name.to_s.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, name.to_s)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end
  end
end
