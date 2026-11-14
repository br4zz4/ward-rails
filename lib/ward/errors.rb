module Ward
  class Error < StandardError; end

  class MissingContext < Error; end

  class BinaryNotFound < Error; end

  class BinaryMismatch < Error; end

  class BinaryOutdated < Error; end

  class LoadFailed < Error; end

  class MissingSecret < Error; end

  class KeyUnavailable < Error; end

  class ChecksumMismatch < Error; end

  class DownloadFailed < Error; end

  class UnsupportedPlatform < Error; end
end
