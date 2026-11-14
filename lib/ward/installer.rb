require "digest"
require "fileutils"
require "net/http"
require "open3"
require "rubygems/package"
require "tmpdir"
require "uri"
require "zlib"

require "ward/errors"
require "ward/version"

module Ward
  # Downloads the pinned ward release asset for the current platform, verifies
  # its sha256 against checksums.txt and installs it atomically into bin/ward.
  class Installer
    BASE_URL = "https://github.com/br4zz4/ward/releases/download"

    def initialize(root:, version: WARD_MIN_VERSION, base_url: BASE_URL)
      @root = root.to_s
      @version = version
      @base_url = base_url
    end

    def install!
      FileUtils.mkdir_p(bin_dir)
      Dir.mktmpdir("ward-install") do |tmp|
        tarball = File.join(tmp, asset)
        checksums = File.join(tmp, "checksums.txt")
        download(url_for(asset), tarball, hint: "no #{asset} in ward #{@version} — check the release page")
        download(url_for("checksums.txt"), checksums)
        verify!(tarball, checksums)
        staged = stage(extract(tarball, tmp))
        target = File.join(bin_dir, "ward")
        install_atomically(staged, target)
        target
      end
    end

    def asset
      "ward_#{platform_os}_#{platform_arch}.tar.gz"
    end

    def platform_os
      case RUBY_PLATFORM
      when /darwin/ then "darwin"
      when /linux/ then "linux"
      else raise UnsupportedPlatform, "ward ships no binary for this OS (#{RUBY_PLATFORM})"
      end
    end

    def platform_arch
      case RUBY_PLATFORM
      when /arm64|aarch64/ then "arm64"
      when /x86_64|amd64/ then "amd64"
      else raise UnsupportedPlatform, "ward ships no binary for this arch (#{RUBY_PLATFORM})"
      end
    end

    private

    def bin_dir
      File.join(@root, "bin")
    end

    def url_for(name)
      "#{@base_url}/v#{@version}/#{name}"
    end

    def download(url, path, redirects = 0, hint: nil)
      raise DownloadFailed, "too many redirects fetching #{url}" if redirects > 5

      uri = parse_url(url, hint)
      return copy_local(uri, path, hint) if uri.scheme == "file"

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri))
      end

      case response
      when Net::HTTPRedirection
        download(response["location"], path, redirects + 1, hint: hint)
      when Net::HTTPSuccess
        File.binwrite(path, response.body)
        path
      else
        suffix = response.code == "404" && hint ? " — #{hint}" : ""
        raise DownloadFailed, "failed to download #{url} (HTTP #{response.code})#{suffix}"
      end
    rescue Timeout::Error, SocketError, SystemCallError => e
      raise DownloadFailed, "failed to download #{url}: #{e.class}"
    end

    # file:// sources enable air-gapped builds from a vendored release directory
    # (same layout as the GitHub release: v<version>/ward_<os>_<arch>.tar.gz +
    # checksums.txt). Checksums are still verified by the caller.
    def copy_local(uri, path, hint)
      source = URI::DEFAULT_PARSER.unescape(uri.path)
      unless File.file?(source)
        suffix = hint ? " — #{hint}" : ""
        raise DownloadFailed, "missing local release file #{source}#{suffix}"
      end

      FileUtils.cp(source, path)
      path
    end

    # File paths are not URLs: a raw space (common in CI checkouts) is illegal in
    # a URI, while "+" is a literal character and must survive unescaping.
    def parse_url(url, hint)
      candidate = url.to_s.start_with?("file://") ? url.to_s.gsub(" ", "%20") : url
      URI.parse(candidate)
    rescue URI::InvalidURIError
      suffix = hint ? " — #{hint}" : ""
      raise DownloadFailed, "invalid install URL #{url.inspect} — percent-encode special characters#{suffix}"
    end

    def verify!(tarball, checksums)
      expected = File.readlines(checksums).filter_map do |line|
        digest, name = line.split
        digest if name == asset
      end.first
      raise ChecksumMismatch, "checksums.txt has no entry for #{asset}" unless expected

      actual = Digest::SHA256.file(tarball).hexdigest
      return if actual == expected

      FileUtils.rm_f(tarball)
      raise ChecksumMismatch, "checksum mismatch for #{asset}: expected #{expected}, got #{actual}"
    end

    def extract(tarball, dir)
      Zlib::GzipReader.open(tarball) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            next unless entry.file? && File.basename(entry.full_name) == "ward"

            return write_entry(entry, dir)
          end
        end
      end
      raise DownloadFailed, "archive #{File.basename(tarball)} does not contain the ward binary"
    end

    def write_entry(entry, dir)
      output = File.join(dir, "ward")
      File.binwrite(output, entry.read)
      output
    end

    # The candidate is made executable and run while still in the temp dir, so a
    # binary that cannot run never becomes bin/ward — and a working binary that
    # was already there is never overwritten by a broken one.
    def stage(path)
      FileUtils.chmod(0o755, path)
      verify_executes!(path)
      path
    end

    def install_atomically(staged, target)
      pending = "#{target}.new"
      FileUtils.cp(staged, pending)
      FileUtils.chmod(0o755, pending)
      File.rename(pending, target)
    ensure
      FileUtils.rm_f(pending)
    end

    def verify_executes!(path)
      _stdout, stderr, status = Open3.capture3(path, "version")
      return if status.success?

      raise DownloadFailed, "downloaded #{asset} but it cannot run on #{RUBY_PLATFORM}: #{stderr.to_s.strip}"
    rescue Errno::ENOEXEC
      raise DownloadFailed, "downloaded #{asset} but it cannot run on #{RUBY_PLATFORM} — wrong platform asset?"
    rescue Errno::ENOENT
      raise DownloadFailed, "downloaded #{asset} but it cannot be started on #{RUBY_PLATFORM} — wrong platform asset?"
    end
  end
end
