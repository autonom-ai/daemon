module Agent
  # Waiters are in-memory only: a waiter is a fact about a live MCP process,
  # not about the bus. A process that dies leaves nobody to wake, so nothing is
  # persisted and nothing needs cleaning up.
  module Waiters
    class Waiter
      def initialize
        @lock = Mutex.new
        @condition = ConditionVariable.new
        @woken = false
      end

      # A wake that lands before the wait is not lost: the flag is already set
      # when the wait starts, so it returns without sleeping.
      def wait(timeout)
        @lock.synchronize do
          @condition.wait(@lock, timeout) unless @woken
          @woken = false
        end
      end

      def wake
        @lock.synchronize do
          @woken = true
          @condition.signal
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

      def wait(key, timeout)
        waiter = Waiter.new
        @lock.synchronize { (@entries[key] ||= []) << waiter }
        waiter.wait(timeout)
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
