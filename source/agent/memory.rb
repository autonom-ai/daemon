require_relative '../profile_store'

module Agent
  # What a person remembers when a session starts: the whole memory while it is
  # small, otherwise the sections that matter - who the person is,
  # project-tagged entries, then the newest dated ones.
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

    private

    def directory(name, root:)
      profile = ProfileStore.get_profiles(root: root).find { |candidate| candidate['name'].casecmp?(name.to_s) }
      profile&.fetch('directory', nil)
    end
  end
end
