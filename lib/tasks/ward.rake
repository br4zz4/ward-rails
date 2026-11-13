require "ward/version"
require "ward/installer"

namespace :ward do
  desc "Download the pinned ward binary and install it into bin/ward"
  task :install do
    root = defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root : Dir.pwd
    target = Ward::Installer.new(root: root).install!
    puts "ward #{Ward::WARD_MIN_VERSION} installed at #{target}"
  end
end
