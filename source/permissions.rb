require 'json'
require 'shellwords'

require_relative 'policy'
require_relative 'profile_store'
require_relative 'workspace'

module Permissions
  def can_read?(path)
    can_access?(path)
  end

  def can_write?(path)
    can_access?(path, write: true)
  end

  def can_search?(path)
    return false unless can_read?(path)

    path = resolve(path, Workspace.project_dir)
    agents = resolve(File.join(ProfileStore.root, 'agents'), Workspace.project_dir)
    prefix = path.end_with?(File::SEPARATOR) ? path : "#{path}#{File::SEPARATOR}"
    return false if guard?('profiles') && agents.start_with?(prefix)

    # A search rooted at or above a hidden room would read its messages, and a
    # search cannot filter its own results. Fails closed.
    return false if guard?('rooms') && hidden_room_dirs.any? { |dir| dir == path || dir.start_with?(prefix) }

    true
  end

  def can_glob?(pattern, path:)
    return false unless pattern.is_a?(String) && !pattern.empty?
    return false unless can_read?(path)

    base = resolve(path, Workspace.project_dir)
    glob = File.expand_path(pattern, base)
    restricted = []
    if guard?('profiles')
      agents = resolve(File.join(ProfileStore.root, 'agents'), Workspace.project_dir)
      restricted.concat(
        [
          agents,
          File.join(agents, 'sessions.json'),
          File.join(agents, 'sessions.json.lock'),
          *Dir.glob(File.join(agents, '.sessions-*'))
        ]
      )
      ProfileStore.profiles.each do |profile|
        next if @name && profile.name.casecmp?(@name)

        restricted.concat(Dir.glob(File.join(profile.directory, '**', '*'), File::FNM_DOTMATCH))
      end
    end
    if guard?('rooms')
      hidden_room_dirs.each do |dir|
        restricted << dir
        restricted.concat(Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH))
      end
    end

    flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
    return false if restricted.any? { |path| File.fnmatch?(glob, path, flags) }

    Dir.glob(glob, File::FNM_DOTMATCH).all? { |path| can_read?(path) }
  rescue ArgumentError, SystemCallError
    false
  end

  def can_exec?(cmd, dir: nil)
    dir ||= Workspace.project_dir
    return false unless cmd.is_a?(String)
    return false unless can_read?(dir)
    return true unless guard?('exec')
    return false if deletes_protected?(cmd, dir: dir)

    shell_paths(cmd).all? { |path| can_read?(path) && can_write?(path) }
  end

  private

  def can_access?(path, write: false)
    return false unless path.is_a?(String) && !path.empty?

    path = resolve(path, Workspace.project_dir)
    name = File.basename(path)
    return false if guard?('env') && (name == '.env' || name.start_with?('.env.'))
    return false if guard?('policy') && policy_path?(path)

    room = guard?('rooms') ? room_access(path, write: write) : nil
    return room unless room.nil?

    root = resolve(ProfileStore.root, Workspace.project_dir)
    agents = resolve(File.join(root, 'agents'), Workspace.project_dir)
    if guard?('profiles') && under?(path, agents)
      relative = path.delete_prefix("#{agents}#{File::SEPARATOR}")
      return false if relative.empty? || store_file?(relative)
      return false if write && File.basename(path) == 'room.json'

      name = relative.split(File::SEPARATOR).first
      return @name && @name.casecmp?(name)
    end

    name = profile_name(path)
    if guard?('profiles') && name
      return false if store_file?(name) || (write && File.basename(path) == 'room.json')

      return @name && @name.casecmp?(name)
    end

    # The codebase itself is not a scratch space; the guards above have
    # already claimed the writable corners under it.
    return false if write && guard?('codebase') && under?(path, root)

    true
  end

  def policy_path?(path)
    path == resolve(Workspace.policy_path, Workspace.project_dir)
  end

  # A path inside a room folder, or nil when it is not one. `messages.jsonl`
  # and `policy.yml` are visible to members; only owners/admins may change policy.
  # `profiles.json` is never a tool's business.
  def room_access(path, write:)
    root = rooms_root
    prefix = "#{root}#{File::SEPARATOR}"
    return nil unless path == root || path.start_with?(prefix)
    return false if path == root

    room_name, file = path.delete_prefix(prefix).split(File::SEPARATOR)
    return false if room_name.nil? || file.nil?

    membership = room_membership(room_name)
    return false unless membership

    case file
    when 'messages.jsonl' then membership[:visible]
    when 'policy.yml' then membership[:visible] && (!write || membership[:administrator])
    else false
    end
  end

  # Membership read straight from the room's profiles.json. Permissions cannot
  # depend on the Bus (that would close a require cycle), so the ladder lives
  # here as well - it is the same ladder Room enforces.
  def room_membership(room_name)
    return nil if @name.to_s.empty?

    data = JSON.parse(File.read(File.join(rooms_root, room_name, 'profiles.json')))
    return nil unless data.is_a?(Hash)

    owner = data['owner'].to_s
    original = (!owner.empty? && owner.casecmp?(@name)) || ProfileStore::HUMAN_NAME.casecmp?(@name)
    admin = Array(data['admins']).any? { |name| name.to_s.casecmp?(@name) }
    involved = data['involved']
    member = involved.nil? || Array(involved).any? { |name| name.to_s.casecmp?(@name) }
    { administrator: original || admin, visible: original || admin || member }
  rescue SystemCallError, JSON::ParserError
    nil
  end

  def hidden_room_dirs
    root = rooms_root
    return [] unless File.directory?(root)

    Dir.children(root).filter_map do |entry|
      dir = File.join(root, entry)
      next unless File.directory?(dir)

      membership = room_membership(entry)
      dir unless membership && membership[:visible]
    end
  end

  def rooms_root
    resolve(Workspace.rooms_dir, Workspace.project_dir)
  end

  # A named guard from the workspace policy applies to this actor unless the
  # policy exempts the profile.
  def guard?(name)
    Policy.workspace.guard?(name, @name)
  end

  def under?(path, dir)
    path == dir || path.start_with?("#{dir}#{File::SEPARATOR}")
  end

  def shell_paths(cmd)
    Shellwords.shellsplit(cmd).select do |arg|
      arg.include?(File::SEPARATOR) ||
        arg.include?('\\') ||
        arg.start_with?('.', '~') ||
        arg.match?(/\A\$\{?HOME\}?/)
    end
  rescue ArgumentError
    []
  end

  def profile_name(path)
    match = %r{(?:\A|/)agents/([^/]+)(?:/|\z)}i.match(path.to_s.tr('\\', '/'))
    match && match[1]
  end

  def store_file?(path)
    name = path.to_s.split(/[\\\/]/).first.to_s.downcase
    name.start_with?('sessions.json', '.sessions-') || name == 'sessions.json.lock'
  end

  def deletes_protected?(cmd, dir:)
    return false unless cmd.match?(/\b(?:rm|rmdir|shred)\b/i)

    paths = shell_paths(cmd).map { |path| resolve(path, dir) }
    paths.any? do |path|
      path == resolve(Dir.home, dir) ||
        path == resolve(File.join(ProfileStore.root, 'source'), dir) ||
        path == resolve(File::SEPARATOR, dir)
    end
  end

  def resolve(path, dir)
    path = path.to_s
      .sub(/\A~(?=\/|\z)/, Dir.home)
      .gsub(/\$\{?HOME\}?/, Dir.home)
    path = File.expand_path(path, dir)
    probe = path
    suffix = []

    until File.exist?(probe) || File.symlink?(probe)
      parent = File.dirname(probe)
      break if parent == probe

      suffix.unshift(File.basename(probe))
      probe = parent
    end

    File.join(File.realpath(probe), *suffix)
  rescue SystemCallError
    path
  end
end

class Unclaimed
  include Permissions

  def initialize()
    @name = nil
  end
end
