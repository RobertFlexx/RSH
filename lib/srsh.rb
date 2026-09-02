# frozen_string_literal: true

require_relative 'srsh/version'

if RUBY_VERSION.partition('.').first.to_i < 4
  raise LoadError, "srsh #{Srsh::VERSION} requires Ruby 4.0 or newer; found Ruby #{RUBY_VERSION}"
end

begin
  require 'srsh_native'
rescue LoadError
  begin
    require_relative '../ext/srsh_native/srsh_native'
  rescue LoadError
    # Optional: the complete shell remains Ruby-only when this is absent.
  end
end

require_relative 'srsh/app'

require_relative 'srsh/process_identity'
