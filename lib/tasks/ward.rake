require "ward/version"
require "ward/installer"
require "ward/release"
require "ward/doctor"

namespace :ward do
  desc "Print the resolved ward setup (no secret values) and flag problems"
  task :doctor do
    exit 1 unless Ward::Doctor.new(Ward.configuration).run
  end

  desc "Download the pinned ward binary and install it into bin/ward"
  task :install do
    root = defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root : Dir.pwd
    base_url = ENV["WARD_INSTALL_BASE_URL"]
    installer = base_url ? Ward::Installer.new(root: root, base_url: base_url) : Ward::Installer.new(root: root)
    target = installer.install!
    puts "ward #{Ward::WARD_MIN_VERSION} installed at #{target}"
  end

  desc "Move WARD_MIN_VERSION to the latest ward release and install that binary"
  task :update do
    root = File.expand_path("../..", __dir__)
    unless File.exist?(File.join(root, "ward-rails.gemspec"))
      abort "ward:update only runs inside the ward-rails source tree (no gemspec at #{root})"
    end

    requested = ENV["WARD_VERSION"].to_s.strip.sub(/\Av/, "")
    if ENV.key?("WARD_VERSION") && requested.empty?
      abort "WARD_VERSION is set but empty — provide a version like 0.4.1 (no leading v)"
    end

    version = requested.empty? ? Ward::Release.latest : requested
    unless version.match?(/\A\d+\.\d+\.\d+\z/)
      abort "invalid ward version #{version.inspect} — expected a stable x.y.z"
    end

    version_file = File.join(root, "lib", "ward", "version.rb")
    pinned = File.read(version_file)[/WARD_MIN_VERSION = "([^"]+)"/, 1].to_s
    if !pinned.empty? && Gem::Version.new(version) <= Gem::Version.new(pinned)
      puts "pinned ward version #{pinned} is up to date (latest available: #{version})"
      next
    end

    previous = Ward::Release.bump!(path: version_file, version: version)
    puts(previous == version ? "pinned ward version already #{version}" : "pinned ward version: #{previous} -> #{version}")

    base_url = ENV["WARD_INSTALL_BASE_URL"]
    installer = base_url ? Ward::Installer.new(root: root, version: version, base_url: base_url) : Ward::Installer.new(root: root, version: version)
    target = installer.install!
    puts "ward #{version} installed at #{target}"
  end
end
