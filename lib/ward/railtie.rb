require "ward"

module Ward
  class Railtie < ::Rails::Railtie
    config.ward = Ward::Configuration.new

    initializer "ward.configuration" do |app|
      config.ward.dir ||= app.root
      Ward.configuration = config.ward
    end

    config.after_initialize do
      Ward.boot!
    end

    rake_tasks do
      load File.expand_path("../tasks/ward.rake", __dir__)
    end
  end
end
