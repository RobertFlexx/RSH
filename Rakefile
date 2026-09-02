require 'rake/testtask'
require 'rake/clean'
require 'rbconfig'

Rake::TestTask.new do |t|
  t.libs << 'lib'
  t.pattern = 'test/test_*.rb'
end

desc 'Build optional native lexer helper'
task :native do
  Dir.chdir('ext/srsh_native') do
    ruby = RbConfig.ruby
    sh ruby, 'extconf.rb'
    sh ENV.fetch('MAKE', 'make')
  end
end

task default: :test
