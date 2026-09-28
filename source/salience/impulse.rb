# The vocabulary of what an agent could be told to do next. A kind is one of
# KINDS - the channel it lands on, the action it names, how it outranks the
# others, and whether it is an obligation. `origin` records what noticed it:
# 'unread' from the bus, 'activity' from the drives.
module Salience
  class Impulse
    MAX_CONTEXT = 2400

    KINDS = {
      'Respond' => {
        'channel' => 'Action',
        'action' => 'Answer the direct communication waiting for you.',
        'priority' => 5,
        'required' => true
      },
      'Coordinate' => {
        'channel' => 'Action',
        'action' => 'Join the most relevant open team thread.',
        'priority' => 4,
        'required' => false
      },
      'Continue' => {
        'channel' => 'Action',
        'action' => 'Continue the most valuable unfinished current work.',
        'priority' => 3,
        'required' => false
      },
      'Report' => {
        'channel' => 'Action',
        'action' => 'Tell the room what you are doing and what you found.',
        'priority' => 3,
        'required' => false
      },
      'Explore' => {
        'channel' => 'Action',
        'action' => 'Pursue the lead that best matches your interests.',
        'priority' => 2,
        'required' => false
      }
    }.freeze

    def initialize(kind, context, origin: 'unread')
      raise ArgumentError, "Unknown impulse: #{kind}" unless KINDS.key?(kind)

      @kind = kind
      @context = context.to_s[0, MAX_CONTEXT]
      @origin = origin.to_s
    end

    attr_reader :kind, :context, :origin

    def action
      KINDS.fetch(kind)['action']
    end

    def channel
      KINDS.fetch(kind)['channel']
    end

    def priority
      KINDS.fetch(kind)['priority']
    end

    def required?
      KINDS.fetch(kind)['required']
    end
  end
end
