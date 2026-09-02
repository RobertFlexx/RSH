require_relative 'lib/srsh/version'

Gem::Specification.new do |s|
  s.name = 'srsh'
  s.version = Srsh::VERSION
  s.summary = 'Simple Ruby Shell with the RSH scripting language'
  s.description = 'A Unix shell written in Ruby with a structured scripting language for shell programs.'
  s.authors = ['RobertFlexx']
  s.license = 'MIT'
  s.homepage = 'https://github.com/RobertFlexx/RSH'
  s.metadata = {
    'source_code_uri' => 'https://github.com/RobertFlexx/RSH',
    'bug_tracker_uri' => 'https://github.com/RobertFlexx/RSH/issues',
    'rubygems_mfa_required' => 'true'
  }
  s.required_ruby_version = '>= 3.2'
  s.files = Dir['bin/*', 'lib/**/*.rb', 'ext/**/*.{c,rb}', 'docs/**/*', 'language-docs/**/*', 'examples/**/*', 'README.md', 'LICENSE']
  s.bindir = 'bin'
  s.executables = ['srsh']
  s.require_paths = ['lib']
  s.extensions = ['ext/srsh_native/extconf.rb']
end
