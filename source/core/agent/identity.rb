require_relative 'store'

module Agent
  # Who a person is when they wake up: the identity file's frontmatter and
  # body, the memory slice a session starts from, and the leanings their
  # teammates have stated. Identity files are clone content, so they follow
  # the person across workspaces.
  module Identity
    MAX_MEMORY = 4000
    MAX_PRIOR = 800

    extend self

    def get(name, root: Store::ROOT)
      dir = directory(name, root: root)
      return nil unless dir

      path = File.join(dir, 'identity.md')
      return nil unless File.file?(path)

      meta, body = split_frontmatter(File.read(path))
      {
        'name' => File.basename(dir),
        'display_name' => meta['displayName']&.strip || File.basename(dir),
        'color' => color(meta['color']),
        'personality' => body.strip
      }
    end

    # The whole file while it is small, otherwise the sections that matter:
    # who the person is, project-tagged entries, then the newest dated ones.
    def memory(name, project, max_chars: MAX_MEMORY, root: Store::ROOT)
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

    # Teammate priors: what the others reach for and avoid, from the sections
    # the identity scaffold writes.
    def priors(root: Store::ROOT, skip: nil)
      Store.get_profiles(root: root).filter_map do |profile|
        next if skip && profile['name'].casecmp?(skip.to_s)

        identity = get(profile['name'], root: root)
        next unless identity

        digest = identity['personality']
          .scan(/^##\s*(Interests|Disinterests)\b(.*?)(?=^##\s|\z)/m)
          .map { |title, body| "### #{title}\n#{body.strip}" }
          .join("\n")
          .strip
        "#{identity['display_name']}:\n#{digest[0, MAX_PRIOR]}" unless digest.empty?
      end
    end

    private

    def directory(name, root:)
      profile = Store.get_profiles(root: root).find { |candidate| candidate['name'].casecmp?(name.to_s) }
      profile&.fetch('directory', nil)
    end

    # Frontmatter is the leading --- block and ONLY that block: a body line
    # like "Rule: read the room first" is not metadata.
    def split_frontmatter(raw)
      match = /\A---\n(.*?)\n---\n?/m.match(raw)
      return [{}, raw] unless match

      meta = {}
      match[1].split("\n").each do |line|
        entry = /\A(\w[\w-]*):\s*(.*)\z/.match(line.strip)
        meta[entry[1]] = entry[2] if entry
      end
      [meta, raw[match[0].length..]]
    end

    def color(value)
      color = value.to_s.strip.gsub(/\A["']|["']\z/, '')
      color.empty? || color == 'null' ? nil : color
    end
  end
end
