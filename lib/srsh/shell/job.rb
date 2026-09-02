module Srsh
  module Shell
    class Job
      WAIT_FLAGS = begin
        flags = Process::WNOHANG | Process::WUNTRACED
        flags |= Process.const_get(:WCONTINUED) if Process.const_defined?(:WCONTINUED)
        flags
      end

      attr_accessor :id, :notified
      attr_reader :pgid, :pids, :command, :status

      def initialize(pgid:, pids:, command:, background:)
        @pgid = pgid
        @pids = pids.freeze
        @command = command
        @background = background
        @pid_states = pids.to_h { |pid| [pid, :running] }
        @status = :running
        @notified = false
      end

      def background? = @background
      def running? = @status == :running
      def stopped? = @status == :stopped
      def done? = @status == :done

      def mark_background! = @background = true
      def mark_foreground! = @background = false

      def mark_running!
        @pid_states.each_key do |pid|
          @pid_states[pid] = :running unless @pid_states[pid] == :done
        end
        recalculate!
      end

      def mark_stopped!(pid = nil)
        if pid
          @pid_states[pid] = :stopped unless @pid_states[pid] == :done
        else
          @pid_states.each_key { |p| @pid_states[p] = :stopped unless @pid_states[p] == :done }
        end
        recalculate!
      end

      def observe(pid, process_status)
        return self unless @pid_states.key?(pid)
        if process_status.stopped?
          @pid_states[pid] = :stopped
        elsif process_status.exited? || process_status.signaled?
          @pid_states[pid] = :done
        elsif process_status.respond_to?(:continued?) && process_status.continued?
          @pid_states[pid] = :running
        end
        recalculate!
      end

      def refresh!
        return self if done?

        @pids.each do |pid|
          next if @pid_states[pid] == :done
          begin
            result = Process.waitpid2(pid, WAIT_FLAGS)
            observe(*result) if result
          rescue Errno::ECHILD
            # No waitable child means it was reaped by the synchronous path or
            # elsewhere in srsh. Treat it as terminal, never as magically live.
            @pid_states[pid] = :done
          rescue Errno::EINVAL
            # Some libc/Ruby combinations expose a wait flag constant but reject
            # the combination at runtime. Retry with the universally portable set.
            begin
              result = Process.waitpid2(pid, Process::WNOHANG | Process::WUNTRACED)
              observe(*result) if result
            rescue Errno::ECHILD
              @pid_states[pid] = :done
            end
          end
        end

        recalculate!
      end

      private

      def recalculate!
        states = @pid_states.values
        @status = if states.all? { |s| s == :done }
                    :done
                  elsif states.none? { |s| s == :running } && states.any? { |s| s == :stopped }
                    :stopped
                  else
                    :running
                  end
        self
      end
    end
  end
end
