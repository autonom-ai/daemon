module Hooks
  module Responses
    def context(event_name, text)
      {
        'hookSpecificOutput' => {
          'hookEventName' => event_name,
          'additionalContext' => text
        }
      }
    end

    def block(reason)
      { 'decision' => 'block', 'reason' => reason }
    end
  end
end
