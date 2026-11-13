require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"]
  task.warning = false
end

Dir[File.join(__dir__, "lib/tasks/**/*.rake")].sort.each { |file| load file }

task default: :test
