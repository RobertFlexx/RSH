module Srsh
  class State
    attr_accessor :theme_name
    attr_reader :aliases, :functions, :prototypes, :traits, :hooks, :jobs, :owner_thread, :options

    def initialize
      @owner_thread = Thread.current
      @last_status = 0
      @last_bg_pid = nil
      @theme_name = 'classic'
      @options = { 'pipefail' => false, 'nounset' => false, 'noclobber' => false }
      @aliases = {}
      @functions = {}
      @prototypes = {}
      @traits = {}
      @hooks = Hash.new { |h, k| h[k] = [] }
      @root_locals = {}
      @owner_locals = [@root_locals]
      @scope_key = :"srsh_scopes_#{object_id}"
      @status_key = :"srsh_status_#{object_id}"
      @bg_key = :"srsh_bg_#{object_id}"
      @jobs = []
      @jobs_lock = Mutex.new
      @next_job_id = 1
    end

    # RSH threads share global definitions and the root interactive scope for
    # reads, but each OS thread gets its own scope stack. Function/lambda calls
    # therefore cannot stomp another thread's locals while closures still see
    # the snapshot they captured.
    def locals
      return @owner_locals if Thread.current == @owner_thread
      Thread.current[@scope_key] ||= [@root_locals]
    end

    def push_scope(seed = {}) = locals << seed

    def pop_scope
      stack = locals
      stack.pop if stack.length > 1
    end

    def local_get(name)
      locals.reverse_each { |scope| return scope[name] if scope.key?(name) }
      nil
    end

    def local_defined?(name) = locals.reverse_each.any? { |s| s.key?(name) }

    def locals_snapshot
      locals.each_with_object({}) { |scope, merged| merged.merge!(scope) }
    end

    # `:=` always binds in the current lexical/function scope. Compound
    # assignment walks outward to the nearest existing binding.
    def local_define(name, value) = locals.last[name] = value

    def local_set(name, value)
      stack = locals
      if worker_thread?
        # Never let an ordinary compound assignment in a worker mutate the
        # shared root REPL/script scope. If the binding only exists globally,
        # shadow it in the task's current scope instead.
        scope = stack[1..].to_a.reverse.find { |s| s.key?(name) } || stack.last
      else
        scope = stack.reverse.find { |s| s.key?(name) } || stack.last
      end
      scope[name] = value
    end

    def last_status
      return @last_status if Thread.current == @owner_thread
      Thread.current[@status_key].nil? ? @last_status : Thread.current[@status_key]
    end

    def last_status=(value)
      if Thread.current == @owner_thread
        @last_status = value
      else
        Thread.current[@status_key] = value
      end
    end

    def last_bg_pid
      return @last_bg_pid if Thread.current == @owner_thread
      Thread.current[@bg_key].nil? ? @last_bg_pid : Thread.current[@bg_key]
    end

    def last_bg_pid=(value)
      if Thread.current == @owner_thread
        @last_bg_pid = value
      else
        Thread.current[@bg_key] = value
      end
    end

    def worker_thread? = Thread.current != @owner_thread

    def add_job(job)
      @jobs_lock.synchronize do
        job.id = @next_job_id
        @next_job_id += 1
        @jobs << job
      end
      job
    end

    def jobs_snapshot = @jobs_lock.synchronize { @jobs.dup }

    def prune_jobs!
      snapshot = jobs_snapshot
      snapshot.each do |job|
        next if job.done?
        begin
          job.refresh!
        rescue StandardError => e
          # Job bookkeeping is housekeeping. A platform-specific wait quirk must
          # never tear down the user's interactive shell.
          warn "srsh: job refresh failed for [#{job.id || '?'}]: #{e.class}: #{e.message}"
        end
      end
      @jobs_lock.synchronize { @jobs.reject! { |job| job.done? && job.notified } }
    end

    def hook(type, &block) = @hooks[type.to_sym] << block
    def clear_hooks! = @hooks.clear

    def run_hooks(type, *args)
      @hooks[type.to_sym].each do |block|
        block.call(*args)
      rescue StandardError => e
        warn "srsh hook #{type}: #{e.class}: #{e.message}"
      end
    end
  end
end
