require "json"
require "net/http"
require "uri"

require "ward/errors"

module Ward
  # Finds the latest ward release and moves the pinned version constant.
  module Release
    API_URL = "https://api.github.com/repos/br4zz4/ward/releases/latest"

    module_function

    def latest(endpoint: API_URL)
      uri = URI.parse(endpoint)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri, "Accept" => "application/vnd.github+json", "User-Agent" => "ward-rails"))
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise DownloadFailed, "failed to fetch #{endpoint} (HTTP #{response.code})"
      end

      payload = JSON.parse(response.body)
      unless payload.is_a?(Hash)
        raise LoadFailed, "unexpected GitHub release payload from #{endpoint}"
      end

      version = payload.fetch("tag_name", "").to_s.strip.sub(/\Av/, "")
      unless version.match?(/\A\d+\.\d+\.\d+/)
        raise LoadFailed, "unexpected GitHub release payload from #{endpoint}"
      end

      version
    rescue JSON::ParserError, KeyError, TypeError
      raise LoadFailed, "unexpected GitHub release payload from #{endpoint}"
    rescue Timeout::Error, SocketError, SystemCallError => e
      raise DownloadFailed, "failed to fetch #{endpoint}: #{e.class}"
    end

    # Rewrites WARD_MIN_VERSION in version.rb and returns the previous version.
    def bump!(path:, version:)
      content = File.read(path)
      match = content.match(/WARD_MIN_VERSION = "([^"]+)"/)
      raise LoadFailed, "WARD_MIN_VERSION not found in #{path}" unless match

      current = match[1]
      return current if current == version

      File.write(path, content.sub(match[0], %(WARD_MIN_VERSION = "#{version}")))
      current
    rescue Errno::ENOENT
      raise LoadFailed, "version file not found: #{path}"
    end
  end
end
