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
  end
end
