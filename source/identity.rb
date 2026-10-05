# Who a person is when they wake up: the identity file's frontmatter and
# body, and the leanings their teammates have stated. Identity files are
# clone content, so they follow the person across workspaces.
class Identity
  FILE = 'identity.md'
  MAX_PRIOR = 800

  # Teammate priors: what the others reach for and avoid, from the sections
  # the identity scaffold writes.
  def self.priors(profiles, skip_profile_name: nil)
    profiles.filter_map do |profile|
      next if skip_profile_name && profile.name.casecmp?(skip_profile_name.to_s)

      digest = profile.identity.digest
      "#{profile.identity.display_name}:\n#{digest[0, MAX_PRIOR]}" unless digest.empty?
    end
  end

  def initialize(profile)
    @profile = profile
  end

  def get()
    identity_path = File.join(@profile.directory, FILE)
    return nil unless File.file?(identity_path)

    meta, body = split_frontmatter(File.read(identity_path))
    {
      'name' => @profile.name,
      'display_name' => meta['displayName']&.strip || @profile.name,
      'color' => color(meta['color']),
      'personality' => body.strip
    }
  end

  def display_name
    identity_data = get()
    identity_data ? identity_data['display_name'] : @profile.name
  end

  def digest
    identity_data = get()
    return '' unless identity_data

    identity_data['personality']
      .scan(/^##\s*(Interests|Disinterests)\b(.*?)(?=^##\s|\z)/m)
      .map { |title, body| "### #{title}\n#{body.strip}" }
      .join("\n")
      .strip
  end

  private

  # Frontmatter is the leading --- block and ONLY that block: a body line
  # like "Rule: read the room first" is not metadata.
  def split_frontmatter(markdown)
    match = /\A---\n(.*?)\n---\n?/m.match(markdown)
    return [{}, markdown] unless match

    meta = {}
    match[1].split("\n").each do |line|
      entry = /\A(\w[\w-]*):\s*(.*)\z/.match(line.strip)
      meta[entry[1]] = entry[2] if entry
    end
    [meta, markdown[match[0].length..]]
  end

  def color(value)
    normalized = value.to_s.strip.gsub(/\A["']|["']\z/, '')
    normalized.empty? || normalized == 'null' ? nil : normalized
  end
end
