require_relative "lib/ward/version"

Gem::Specification.new do |spec|
  spec.name = "ward-rails"
  spec.version = Ward::VERSION
  spec.authors = ["gporpino"]
  spec.email = ["gporpino@users.noreply.github.com"]

  spec.summary = "Load ward secrets into a private in-memory store for Rails apps"
  spec.description = "Reads the ward vault at boot through the ward CLI (JSON output) and exposes " \
                     "secrets via a private, frozen in-memory store. Nothing is written to ENV, " \
                     "and boot fails fast with actionable errors."
  spec.homepage = "https://github.com/br4zz4/ward-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 8.0", "< 9.0"
end
