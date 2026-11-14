require "test_helper"
require "ward/release"
require "webrick"

class ReleaseTest < Minitest::Test
  TXT = <<~RUBY
    module Ward
      VERSION = "0.1.0"
      WARD_MIN_VERSION = "0.4.0"
    end
  RUBY

  def with_server(status: 200, body: "")
    server = WEBrick::HTTPServer.new(
      Port: 0,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    server.mount_proc("/") do |_request, response|
      response.status = status
      response.body = body
    end
    thread = Thread.new { server.start }
    port = server.listeners.first.addr[1]
    yield "http://127.0.0.1:#{port}"
  ensure
    server&.shutdown
    thread&.join
  end

  def write_version(content)
    dir = Dir.mktmpdir("ward-release")
    path = File.join(dir, "version.rb")
    File.write(path, content)
    [dir, path]
  end

  def test_latest_returns_version_without_v_prefix
    with_server(body: '{"tag_name":"v0.4.1"}') do |base_url|
      assert_equal "0.4.1", Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
    end
  end

  def test_latest_raises_download_failed_on_http_error
    with_server(status: 500, body: "boom") do |base_url|
      assert_raises(Ward::DownloadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end
    end
  end

  def test_latest_raises_load_failed_on_invalid_json
    with_server(body: "not json") do |base_url|
      assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end
    end
  end

  def test_latest_raises_load_failed_without_tag_name
    with_server(body: '{"name":"v0.4.1"}') do |base_url|
      assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end
    end
  end

  def test_latest_raises_load_failed_on_empty_tag_name
    with_server(body: '{"tag_name":""}') do |base_url|
      assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end
    end
  end

  def test_latest_raises_load_failed_on_bare_v_tag_name
    with_server(body: '{"tag_name":"v"}') do |base_url|
      assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end
    end
  end

  def test_latest_raises_load_failed_on_non_semver_tag_name
    with_server(body: '{"tag_name":"vnext"}') do |base_url|
      assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end
    end
  end

  def test_latest_raises_load_failed_on_array_payload
    with_server(body: '[{"tag_name":"v1"}]') do |base_url|
      error = assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end

      refute_kind_of TypeError, error
      assert_includes error.message, "unexpected GitHub release payload"
    end
  end

  def test_latest_raises_load_failed_on_string_payload
    with_server(body: '"abc"') do |base_url|
      error = assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end

      refute_kind_of TypeError, error
      assert_includes error.message, "unexpected GitHub release payload"
    end
  end

  def test_latest_raises_load_failed_on_numeric_payload
    with_server(body: "42") do |base_url|
      error = assert_raises(Ward::LoadFailed) do
        Ward::Release.latest(endpoint: "#{base_url}/releases/latest")
      end

      refute_kind_of TypeError, error
      assert_includes error.message, "unexpected GitHub release payload"
    end
  end

  def test_bump_rewrites_version_and_returns_previous
    dir, path = write_version(TXT)

    previous = Ward::Release.bump!(path: path, version: "0.4.1")

    assert_equal "0.4.0", previous
    assert_includes File.read(path), 'WARD_MIN_VERSION = "0.4.1"'
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_bump_keeps_file_untouched_when_version_is_current
    dir, path = write_version(TXT)
    Ward::Release.bump!(path: path, version: "0.4.1")
    before = File.read(path)

    previous = Ward::Release.bump!(path: path, version: "0.4.1")

    assert_equal "0.4.1", previous
    assert_equal before, File.read(path)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_bump_raises_load_failed_without_constant
    dir, path = write_version("module Ward\n  VERSION = \"0.1.0\"\nend\n")

    assert_raises(Ward::LoadFailed) { Ward::Release.bump!(path: path, version: "0.4.1") }
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_bump_preserves_rest_of_file
    dir, path = write_version(TXT)

    Ward::Release.bump!(path: path, version: "0.4.1")

    content = File.read(path)
    assert_includes content, 'VERSION = "0.1.0"'
    assert_includes content, "module Ward"
    assert_includes content, "end"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_bump_raises_load_failed_when_version_file_is_missing
    Dir.mktmpdir("ward-release") do |dir|
      error = assert_raises(Ward::LoadFailed) do
        Ward::Release.bump!(path: File.join(dir, "missing.rb"), version: "0.4.1")
      end

      assert_includes error.message, "version file not found"
    end
  end

  def test_rake_lists_ward_update_task
    stdout, stderr, status = Open3.capture3("bundle", "exec", "rake", "-T", chdir: WardTest::ROOT)

    assert status.success?, stderr
    assert_includes stdout, "ward:update"
  end

  def test_ward_update_aborts_on_empty_version
    before = File.read(version_file)

    _stdout, stderr, status = Open3.capture3(
      { "WARD_VERSION" => "" }, "bundle", "exec", "rake", "ward:update", chdir: WardTest::ROOT
    )

    refute status.success?
    assert_includes stderr, "WARD_VERSION is set but empty"
    assert_equal before, File.read(version_file)
  end

  def test_ward_update_aborts_on_invalid_version
    before = File.read(version_file)

    _stdout, stderr, status = Open3.capture3(
      { "WARD_VERSION" => "vv0.4.1" }, "bundle", "exec", "rake", "ward:update", chdir: WardTest::ROOT
    )

    refute status.success?
    assert_includes stderr, "invalid ward version"
    assert_equal before, File.read(version_file)
  end

  def version_file
    File.join(WardTest::ROOT, "lib", "ward", "version.rb")
  end
end
