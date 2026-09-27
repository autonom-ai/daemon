require_relative '../config'

# Memory is intentionally inert. The layer exists so the hooks and the
# profile boundary are already in the right place, but nothing here recalls
# or writes automatically yet - the evals branch decides what context
# injection is actually worth before any of it runs on a live agent.
#
# What it does today is read the profile's own notes. That is a file read,
# not a memory system, and it is only used to greet a session with what the
# person already wrote down for themselves.
class Memory
  NOTES_FILE = 'memory.md'
  MAX_CHARS = 4000

  def initialize(profile)
    @profile = profile
  end

  def get(max_chars: MAX_CHARS)
    path = File.join(@profile.directory, 'memories', NOTES_FILE)
    return '' unless File.file?(path)

    raw = File.read(path).strip
    return raw if raw.length <= max_chars

    project = Config.project
    blocks = raw.split(/\n(?=\#{1,3}\s)/)
    picked = [
      blocks.select { |block| block.match?(/^\#{1,3}\s*(who i am|self|now)\b/i) },
      blocks.select { |block| project && block.include?("[project:#{project}]") },
      blocks.select { |block| block.match?(/^\#{1,3}\s*\d{4}-\d{2}-\d{2}/) }.last(8)
    ].flatten.uniq.join("\n\n")
    picked.empty? ? raw[-max_chars..] : picked[0, max_chars]
  end

  def recall(query, max_chars: MAX_CHARS)
    ''
  end

  def capture(text)
    false
  end
end
