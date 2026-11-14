require "ward/version"
require "ward/installer"
require "ward/release"

namespace :ward do
  desc "Download the pinned ward binary and install it into bin/ward"
  task :install do
    root = defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root : Dir.pwd
    target = Ward::Installer.new(root: root).install!
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
    abort "invalid ward version #{version.inspect} — expected x.y.z" unless version.match?(/\A\d+\.\d+\.\d+/)

    previous = Ward::Release.bump!(path: File.join(root, "lib", "ward", "version.rb"), version: version)
    puts(previous == version ? "pinned ward version already #{version}" : "pinned ward version: #{previous} -> #{version}")

    target = Ward::Installer.new(root: root, version: version).install!
    puts "ward #{version} installed at #{target}"
  end
end
