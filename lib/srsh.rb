# frozen_string_literal: true

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
