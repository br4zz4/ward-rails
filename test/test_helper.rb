require "minitest/autorun"
require "open3"
require "fileutils"
require "tmpdir"
require "rbconfig"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require_relative "../lib/ward"

ENV["WARD_AI_MODE"] = "0"
ENV.delete_if do |name, _|
  name == "WARD_CONTEXT" ||
    name == "WARD_KEY" ||
    name.start_with?("OPENCODE", "OPENCLAW_", "CLAUDE_")
end

module WardTest
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib")
  DUMMY_ENV = File.join(ROOT, "test", "dummy", "config", "environment.rb")
  FAKE_WARD = File.join(ROOT, "test", "fixtures", "bin", "fake-ward")

  class << self
    def ward_bin
      @ward_bin ||= begin
        path = ENV["WARD_EXECUTABLE_PATH"]
        path = File.join(ROOT, "bin", "ward") if path.nil? || path.empty?
        path = which("ward") unless executable?(path)
        raise "ward binary not found — set WARD_EXECUTABLE_PATH or install ward" unless executable?(path)

        path
      end
    end

    def run_ward(dir, *args)
      stdout, stderr, status = Open3.capture3(ward_bin, *args, chdir: dir)
      raise "ward #{args.join(" ")} failed: #{stderr}" unless status.success?

      stdout
    end

    def create_project(secrets = {})
      root = Dir.mktmpdir("ward-rails-project")
      tracked << root
      project = File.join(root, "main")
      FileUtils.mkdir_p(project)
      run_ward(project, "init")
      secrets.each { |path, value| run_ward(project, "set", "main:#{path}", value) }
      project
    end

    def default_secrets
      {
        "secrets.main.code.production.RESEND_API_KEY" => "fake-value-123",
        "secrets.main.code.production.OUTRA" => "other-value-456"
      }
    end

    def add_locked_vault(project, name: "commons")
      vaults = File.join(project, ".ward", "vaults")
      common = File.join(vaults, name)
      FileUtils.mkdir_p(common)
      FileUtils.cp(File.join(vaults, "main", "secrets.ward"), File.join(common, "secrets.ward"))
      File.write(File.join(project, ".ward", "config.yaml"), <<~YAML)
        vaults:
          - name: main
            path: .ward/vaults/main
          - name: #{name}
            path: .ward/vaults/#{name}
            encryption:
              key_env: WARD_KEY_#{name.upcase}
      YAML
      project
    end

    def run_ruby(env, script)
      Open3.capture3(env, RbConfig.ruby, "-I", LIB, "-e", script, chdir: ROOT)
    end

    def cleanup!
      tracked.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
      tracked.clear
    end

    def tracked
      @tracked ||= []
    end

    private

    def executable?(path)
      !path.to_s.empty? && File.file?(path.to_s) && File.executable?(path.to_s)
    end

    def which(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, name)
        return candidate if executable?(candidate)
      end
      nil
    end
  end
end

module WardTest::EnvHelpers
  def with_env(values)
    saved = ENV.to_h
    values.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    ENV.replace(saved)
  end
end

Minitest::Test.include(WardTest::EnvHelpers)

Minitest.after_run { WardTest.cleanup! }
