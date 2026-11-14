require "test_helper"
require "ward/installer"
require "digest"
require "webrick"
require "zlib"
require "rubygems/package"

class InstallerTest < Minitest::Test
  BINARY = "#!/bin/sh\necho fake-ward\n".freeze

  def with_platform(value)
    original = RUBY_PLATFORM
    verbosity = $VERBOSE
    $VERBOSE = nil
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, value)
    yield
  ensure
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, original)
    $VERBOSE = verbosity
  end

  def with_server(root)
    server = WEBrick::HTTPServer.new(
      Port: 0,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    server.mount_proc("/") do |request, response|
      path = File.join(root, request.path)
      if File.file?(path)
        response.status = 200
        response.body = File.binread(path)
      else
        response.status = 404
        response.body = "not found"
      end
    end
    thread = Thread.new { server.start }
    port = server.listeners.first.addr[1]
    yield "http://127.0.0.1:#{port}"
  ensure
    server&.shutdown
    thread&.join
  end

  def write_tarball(path, files)
    File.open(path, "wb") do |file|
      Zlib::GzipWriter.wrap(file) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          files.each do |name, content|
            tar.add_file_simple(name, 0o755, content.bytesize) { |io| io.write(content) }
          end
        end
      end
    end
  end

  def build_release(root, checksum: :matching, content: BINARY)
    release = File.join(root, "v#{Ward::WARD_MIN_VERSION}")
    FileUtils.mkdir_p(release)
    asset = Ward::Installer.new(root: root).asset
    tarball = File.join(release, asset)
    write_tarball(tarball, "ward" => content)
    digest = checksum == :matching ? Digest::SHA256.hexdigest(File.binread(tarball)) : "0" * 64
    File.write(File.join(release, "checksums.txt"), "#{digest}  #{asset}\n")
    asset
  end

  def test_asset_for_supported_platforms
    installer = Ward::Installer.new(root: "/tmp/ignored")

    with_platform("arm64-darwin23") { assert_equal "ward_darwin_arm64.tar.gz", installer.asset }
    with_platform("x86_64-darwin22") { assert_equal "ward_darwin_amd64.tar.gz", installer.asset }
    with_platform("x86_64-linux") { assert_equal "ward_linux_amd64.tar.gz", installer.asset }
    with_platform("x86_64-linux-musl") { assert_equal "ward_linux_amd64.tar.gz", installer.asset }
    with_platform("aarch64-linux") { assert_equal "ward_linux_arm64.tar.gz", installer.asset }
  end

  def test_unsupported_platform_raises
    installer = Ward::Installer.new(root: "/tmp/ignored")

    with_platform("i386-solaris2.11") do
      assert_raises(Ward::UnsupportedPlatform) { installer.asset }
    end
  end

  def test_install_writes_executable_binary
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root)
      app = File.join(root, "app")

      with_server(root) do |base_url|
        target = Ward::Installer.new(root: app, base_url: base_url).install!

        assert_equal File.join(app, "bin", "ward"), target
        assert_equal BINARY, File.binread(target)
        assert_equal "755", format("%o", File.stat(target).mode & 0o777)
      end
    end
  end

  def test_checksum_mismatch_raises_and_leaves_no_binary
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root, checksum: :mismatch)
      app = File.join(root, "app")

      with_server(root) do |base_url|
        assert_raises(Ward::ChecksumMismatch) do
          Ward::Installer.new(root: app, base_url: base_url).install!
        end
      end

      refute File.exist?(File.join(app, "bin", "ward"))
    end
  end

  def test_missing_release_asset_raises_with_hint_and_leaves_no_binary
    Dir.mktmpdir("ward-installer") do |root|
      app = File.join(root, "app")

      with_server(root) do |base_url|
        installer = Ward::Installer.new(root: app, base_url: base_url)
        error = assert_raises(Ward::DownloadFailed) { installer.install! }

        assert_includes error.message, "HTTP 404"
        assert_includes error.message, "no #{installer.asset} in ward #{Ward::WARD_MIN_VERSION}"
        assert_includes error.message, "check the release page"
      end

      refute File.exist?(File.join(app, "bin", "ward"))
    end
  end

  def test_binary_that_cannot_run_raises_and_leaves_no_binary
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root, content: "garbage-no-magic")
      app = File.join(root, "app")

      with_server(root) do |base_url|
        error = assert_raises(Ward::DownloadFailed) do
          Ward::Installer.new(root: app, base_url: base_url).install!
        end

        assert_includes error.message, "cannot run on"
      end

      refute File.exist?(File.join(app, "bin", "ward"))
    end
  end

  def test_failed_install_preserves_existing_binary
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root, content: "garbage-no-magic")
      app = File.join(root, "app")
      bin_dir = File.join(app, "bin")
      FileUtils.mkdir_p(bin_dir)
      existing = File.join(bin_dir, "ward")
      File.binwrite(existing, "#!/bin/sh\necho GOOD\n")
      FileUtils.chmod(0o755, existing)
      before = File.binread(existing)

      with_server(root) do |base_url|
        assert_raises(Ward::DownloadFailed) do
          Ward::Installer.new(root: app, base_url: base_url).install!
        end
      end

      assert_equal before, File.binread(existing)
      assert_equal "755", format("%o", File.stat(existing).mode & 0o777)
      refute File.exist?("#{existing}.new")
    end
  end

  def test_install_from_file_url
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root)
      app = File.join(root, "app")

      target = Ward::Installer.new(root: app, base_url: "file://#{root}").install!

      assert_equal File.join(app, "bin", "ward"), target
      assert_equal BINARY, File.binread(target)
      assert_equal "755", format("%o", File.stat(target).mode & 0o777)
    end
  end

  def test_file_url_still_verifies_checksum
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root, checksum: :mismatch)
      app = File.join(root, "app")

      assert_raises(Ward::ChecksumMismatch) do
        Ward::Installer.new(root: app, base_url: "file://#{root}").install!
      end

      refute File.exist?(File.join(app, "bin", "ward"))
    end
  end

  def test_file_url_without_release_raises_download_failed
    Dir.mktmpdir("ward-installer") do |root|
      app = File.join(root, "app")

      error = assert_raises(Ward::DownloadFailed) do
        Ward::Installer.new(root: app, base_url: "file://#{root}").install!
      end

      assert_includes error.message, "missing local release file"
      assert_includes error.message, "check the release page"
    end
  end

  def test_file_url_keeps_plus_literal_in_path
    Dir.mktmpdir("ward-installer") do |root|
      release = File.join(root, "repo+branch")
      FileUtils.mkdir_p(release)
      build_release(release)
      app = File.join(root, "app")

      Ward::Installer.new(root: app, base_url: "file://#{release}").install!

      assert_installed_ward(app)
    end
  end

  def test_file_url_normalizes_raw_space_in_path
    Dir.mktmpdir("ward-installer") do |root|
      release = File.join(root, "My Build")
      FileUtils.mkdir_p(release)
      build_release(release)
      app = File.join(root, "app")

      Ward::Installer.new(root: app, base_url: "file://#{release}").install!

      assert_installed_ward(app)
    end
  end

  def test_file_url_accepts_percent_encoded_space
    Dir.mktmpdir("ward-installer") do |root|
      release = File.join(root, "My Build")
      FileUtils.mkdir_p(release)
      build_release(release)
      app = File.join(root, "app")

      Ward::Installer.new(root: app, base_url: "file://#{release.gsub(" ", "%20")}").install!

      assert_installed_ward(app)
    end
  end

  def test_invalid_url_raises_download_failed
    Dir.mktmpdir("ward-installer") do |root|
      app = File.join(root, "app")

      error = assert_raises(Ward::DownloadFailed) do
        Ward::Installer.new(root: app, base_url: "http://exa mple.com").install!
      end

      assert_includes error.message, "invalid install URL"
      refute File.exist?(File.join(app, "bin", "ward"))
    end
  end

  def assert_installed_ward(app)
    target = File.join(app, "bin", "ward")
    assert_equal BINARY, File.binread(target)
    assert_equal "755", format("%o", File.stat(target).mode & 0o777)
    target
  end

  def test_rake_install_from_file_url_end_to_end
    Dir.mktmpdir("ward-release") do |release_root|
      build_release(release_root)
      repo_bin = File.join(WardTest::ROOT, "bin", "ward")
      repo_before = File.exist?(repo_bin) ? File.binread(repo_bin) : nil

      Dir.mktmpdir("ward-app") do |app|
        _stdout, stderr, status = Open3.capture3(
          {
            "BUNDLE_GEMFILE" => File.join(WardTest::ROOT, "Gemfile"),
            "WARD_INSTALL_BASE_URL" => "file://#{release_root}"
          },
          "bundle", "exec", "rake", "-f", File.join(WardTest::ROOT, "lib", "tasks", "ward.rake"),
          "ward:install", chdir: app
        )

        assert status.success?, stderr
        target = File.join(app, "bin", "ward")
        assert File.file?(target), "expected #{target} to exist"
        assert_equal "755", format("%o", File.stat(target).mode & 0o777)
        assert_equal BINARY, File.binread(target)
      end

      if repo_before
        assert_equal repo_before, File.binread(repo_bin), "the run must not modify #{repo_bin}"
      else
        refute File.exist?(repo_bin), "the run must not create #{repo_bin}"
      end
    end
  end

  def test_install_is_idempotent
    Dir.mktmpdir("ward-installer") do |root|
      build_release(root)
      app = File.join(root, "app")

      with_server(root) do |base_url|
        first = Ward::Installer.new(root: app, base_url: base_url).install!
        second = Ward::Installer.new(root: app, base_url: base_url).install!

        assert_equal first, second
        assert_equal BINARY, File.binread(second)
        assert_equal "755", format("%o", File.stat(second).mode & 0o777)
      end
    end
  end

  def test_installer_requires_standalone_without_name_error
    script = 'require "ward/installer"; abort unless Ward::WARD_MIN_VERSION'

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", WardTest::LIB, "-e", script, chdir: WardTest::ROOT
    )

    assert status.success?, "stdout: #{stdout}\nstderr: #{stderr}"
  end

  def test_rake_lists_ward_install_task
    stdout, stderr, status = Open3.capture3("bundle", "exec", "rake", "-T", chdir: WardTest::ROOT)

    assert status.success?, stderr
    assert_includes stdout, "ward:install"
  end
end
