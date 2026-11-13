require "rails"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "ward-rails"

require_relative "application"

Rails.application.initialize!
