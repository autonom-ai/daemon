require_relative '../profile_store'

# Memory is intentionally inert. The layer exists so the hooks and the
# profile boundary are already in the right place, but nothing here recalls
# or writes automatically yet - the evals branch decides what context
# injection is actually worth before any of it runs on a live agent.
#
# What it does today is read the profile's own notes. That is a file read,
# not a memory system, and it is only used to greet a session with what the
# person already wrote down for themselves.
module Memory
  MAX_CHARS = 4000

  extend self

  def get(name, project, max_chars: MAX_CHARS, root: ProfileStore::ROOT)
    dir = directory(name, root: root)
    return '' unless dir

    path = File.join(dir, 'memories', 'memory.md')
    return '' unless File.file?(path)

    raw = File.read(path).strip
    return raw if raw.length <= max_chars

    blocks = raw.split(/\n(?=\#{1,3}\s)/)
    picked = [
      blocks.select { |block| block.match?(/^\#{1,3}\s*(who i am|self|now)\b/i) },
      blocks.select { |block| project && block.include?("[project:#{project}]") },
      blocks.select { |block| block.match?(/^\#{1,3}\s*\d{4}-\d{2}-\d{2}/) }.last(8)
    ].flatten.uniq.join("\n\n")
    picked.empty? ? raw[-max_chars..] : picked[0, max_chars]
  end

  def recall(name, query, project:, session: nil, max_chars: MAX_CHARS, root: ProfileStore::ROOT)
    ''
  end

  def capture(name, text, session: nil, root: ProfileStore::ROOT)
    false
  end

  private

  def directory(name, root:)
    profile = ProfileStore.get_profiles(root: root).find { |candidate| candidate['name'].casecmp?(name.to_s) }
    profile&.fetch('directory', nil)
  end
end
