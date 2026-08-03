# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.verbose = true
end

task default: :test
