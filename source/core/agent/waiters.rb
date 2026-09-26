module Agent
  # Waiters are in-memory only: a waiter is a fact about a live MCP process,
  # not about the bus. A process that dies leaves nobody to wake, so nothing is
  # persisted and nothing needs cleaning up.
  #
  # Nor can anyone else wake it: every session runs its own MCP process, so a
  # sender's signal reaches the waiters in the sender's process and no others —
  # never the process it is talking to. A waiter therefore also watches the
  # files the wake would have written, and returns as soon as one of them grows.
  module Waiters
    extend self

    FIRST_SLICE = 0.05
    MAX_SLICE = 0.5

    # What the watched files looked like when the wait began: size catches an
    # append, mtime and inode catch a rewrite or a replaced file, and a file
    # that is not there yet is a state like any other — its arrival is a change.
    def fingerprint(paths)
      paths.map do |path|
        stat = File.stat(path)
        [stat.size, stat.mtime.to_f, stat.ino]
      rescue SystemCallError
        nil
      end
    end

    class Waiter
      def initialize
        @lock = Mutex.new
        @condition = ConditionVariable.new
        @woken = false
      end

      # A wake that lands before the wait is not lost: the flag is already set
      # when the wait starts, so it returns without sleeping. A wait with files
      # to watch sleeps in slices and looks at them in between, so a write from
      # another process lands within a slice; a wait with nothing to watch
      # sleeps the whole timeout in one go, exactly as before.
      def wait(timeout, watch: [], baseline: nil)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        slice = FIRST_SLICE
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return if remaining <= 0
          return if wait_slice(watch.empty? ? remaining : [slice, remaining].min)
          return if Waiters.fingerprint(watch) != baseline

          slice = [slice * 2, MAX_SLICE].min
        end
      end

      def wake
        @lock.synchronize do
          @woken = true
          @condition.signal
        end
      end

      private

      # One slice of sleep, cut short by a signal. The first slice is short
      # enough that a cross-process write feels immediate; the rest back off so
      # a long wait costs a couple of stats a second rather than a busy poll.
      def wait_slice(seconds)
        @lock.synchronize do
          @condition.wait(@lock, seconds) unless @woken
          return false unless @woken

          @woken = false
          true
        end
      end
    end

    # A key holds every waiter registered for it, so two tabs sharing a profile
    # both wake instead of the second replacing the first.
    class Registry
      def initialize
        @lock = Mutex.new
        @entries = {}
      end

      def wait(key, timeout, watch: [])
        waiter = Waiter.new
        # The files are read before the waiter is registered: a line that lands
        # in the gap is a change the waiter can still see on its next slice, and
        # one that lands after registration is a change too.
        baseline = Waiters.fingerprint(watch)
        @lock.synchronize { (@entries[key] ||= []) << waiter }
        waiter.wait(timeout, watch: watch, baseline: baseline)
      ensure
        @lock.synchronize do
          @entries[key]&.delete(waiter)
          @entries.delete(key) if @entries[key]&.empty?
        end
      end

      def wake(key)
        waiters = @lock.synchronize { @entries[key] }
        waiters&.each(&:wake)
      end

      def wake_all
        waiters = @lock.synchronize { @entries.values.flatten }
        waiters.each(&:wake)
      end
    end
  end
end
