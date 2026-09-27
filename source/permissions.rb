require 'shellwords'

# Access control for the profile it is mixed into: which paths, profiles, and
# shell commands this person may touch. The store and the workspace come from
# the bus the profile holds, so only the tool's own input varies.
module Permissions
  def can_read?(path)
    can_access?(path)
  end

  def can_write?(path)
    can_access?(path)
  end

  def can_search?(path)
    return false unless can_read?(path)

    path = resolve(path, @bus.config.project_dir)
    agents = resolve(File.join(@bus.store.root, 'agents'), @bus.config.project_dir)
    prefix = path.end_with?(File::SEPARATOR) ? path : "#{path}#{File::SEPARATOR}"
    !agents.start_with?(prefix)
  end

  def can_glob?(pattern, path:)
    return false unless pattern.is_a?(String) && !pattern.empty?
    return false unless can_read?(path)

    base = resolve(path, @bus.config.project_dir)
    glob = File.expand_path(pattern, base)
    agents = resolve(File.join(@bus.store.root, 'agents'), @bus.config.project_dir)
    restricted = [
      agents,
      File.join(agents, 'sessions.json'),
      File.join(agents, 'sessions.json.lock'),
      *Dir.glob(File.join(agents, '.sessions-*'))
    ]
    @bus.store.records.each do |record|
      next if @name && record.name.casecmp?(@name)

      restricted.concat(Dir.glob(File.join(record.directory, '**', '*'), File::FNM_DOTMATCH))
    end

    flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
    return false if restricted.any? { |path| File.fnmatch?(glob, path, flags) }

    Dir.glob(glob, File::FNM_DOTMATCH).all? { |path| can_read?(path) }
  rescue ArgumentError, SystemCallError
    false
  end

  def can_exec?(cmd, dir: nil)
    dir ||= @bus.config.project_dir
    return false unless cmd.is_a?(String)
    return false unless can_read?(dir)
    return false if deletes_protected?(cmd, dir: dir)

    shell_paths(cmd).all? { |path| can_read?(path) && can_write?(path) }
  end

  private

  def can_access?(path)
    return false unless path.is_a?(String) && !path.empty?

    path = resolve(path, @bus.config.project_dir)
    root = resolve(@bus.store.root, @bus.config.project_dir)
    name = File.basename(path)
    return false if name == '.env' || name.start_with?('.env.')

    agents = resolve(File.join(root, 'agents'), @bus.config.project_dir)
    if path == agents || path.start_with?("#{agents}#{File::SEPARATOR}")
      relative = path.delete_prefix("#{agents}#{File::SEPARATOR}")
      return false if relative.empty? || store_file?(relative)

      name = relative.split(File::SEPARATOR).first
      return @name && @name.casecmp?(name)
    end

    name = profile_name(path)
    return true unless name
    return false if store_file?(name)

    @name && @name.casecmp?(name)
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
        path == resolve(File.join(@bus.store.root, 'source'), dir) ||
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

# The permissions of a session that has not claimed a profile: it may touch
# the workspace, but nothing that belongs to a profile.
class Unclaimed
  include Permissions

  def initialize(bus)
    @bus = bus
    @name = nil
  end
end
