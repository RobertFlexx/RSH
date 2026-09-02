# frozen_string_literal: true

module Srsh
  module ProcessIdentity
    module_function

    def install!(executable: $PROGRAM_NAME)
      path = File.expand_path(executable.to_s)
      ENV['SHELL'] = path unless path.empty?
      $0 = 'srsh'
      if RUBY_PLATFORM.include?('linux')
        if defined?(::SrshNative) && ::SrshNative.respond_to?(:set_process_name)
          ::SrshNative.set_process_name('srsh')
        else
          linux_process_name('srsh')
        end
      end
      true
    rescue StandardError
      false
    end

    def linux_process_name(name)
      require 'fiddle'
      libc = Fiddle::Handle::DEFAULT
      prctl = Fiddle::Function.new(
        libc['prctl'],
        [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_ULONG, Fiddle::TYPE_ULONG, Fiddle::TYPE_ULONG],
        Fiddle::TYPE_INT
      )
      bytes = name.to_s.byteslice(0, 15).to_s + "\0"
      pointer = Fiddle::Pointer[bytes]
      prctl.call(15, pointer, 0, 0, 0) # PR_SET_NAME
    rescue Fiddle::DLError, LoadError
      false
    end
  end
end
