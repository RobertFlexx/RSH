module Srsh
  module Shell
    module Terminal
      module_function

      begin
        require 'fiddle/import'
        module LibC
          extend Fiddle::Importer
          dlload Fiddle.dlopen(nil)
          extern 'int tcsetpgrp(int, int)'
        end
        AVAILABLE = true
      rescue LoadError, Fiddle::DLError
        AVAILABLE = false
      end

      def foreground(pgid, io = STDIN)
        return false unless AVAILABLE && io.tty?
        LibC.tcsetpgrp(io.fileno, pgid.to_i).zero?
      rescue SystemCallError, Fiddle::DLError
        false
      end
    end
  end
end
