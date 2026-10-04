require 'json'
require 'shellwords'

require_relative '../profile_store'
require_relative '../workspace'
require_relative 'format'

module Policy
  module Access
    extend self

    def permits?(profile_name, kind, path: nil, command: nil, dir: nil)
      return false unless Policy.workspace.permits?(kind, profile_name)
      return command_ok?(profile_name, command, dir) if kind == 'execute'

      path_ok?(profile_name, path, write: kind == 'write')
    end

    def search?(profile_name, path)
      return false unless path_ok?(profile_name, path, write: false)

      path = resolve(path, Workspace.project_dir)
      prefix = path.end_with?(File::SEPARATOR) ? path : "#{path}#{File::SEPARATOR}"
      return false if agents_dir.start_with?(prefix)
      return false if hidden_rooms(profile_name).any? { |dir| dir == path || dir.start_with?(prefix) }

      true
    end

    def glob?(profile_name, pattern, path)
      return false unless pattern.is_a?(String) && !pattern.empty?
      return false unless path_ok?(profile_name, path, write: false)

      base = resolve(path, Workspace.project_dir)
      glob = File.expand_path(pattern, base)
      flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
      return false if restricted(profile_name).any? { |entry| File.fnmatch?(glob, entry, flags) }

      Dir.glob(glob, File::FNM_DOTMATCH).all? { |entry| path_ok?(profile_name, entry, write: false) }
    rescue ArgumentError, SystemCallError
      false
    end

    private

    def command_ok?(profile_name, command, dir)
      dir ||= Workspace.project_dir
      return false unless command.is_a?(String)
      return false unless path_ok?(profile_name, dir, write: false)
      return false if deletes_protected?(command, dir)

      shell_paths(command).all? do |entry|
        path_ok?(profile_name, entry, write: false) && path_ok?(profile_name, entry, write: true)
      end
    end

    def path_ok?(profile_name, path, write:)
      return false unless path.is_a?(String) && !path.empty?

      path = resolve(path, Workspace.project_dir)
      name = File.basename(path)
      return false if name == '.env' || name.start_with?('.env.')
      return false if path == resolve(Workspace.policy_path, Workspace.project_dir)

      room = room_access(profile_name, path, write: write)
      return room unless room.nil?

      agents = agents_dir
      if under?(path, agents)
        relative = path.delete_prefix("#{agents}#{File::SEPARATOR}")
        return false if relative.empty? || store_file?(relative)
        return false if write && File.basename(path) == 'room.json'

        return profile_name.to_s.casecmp?(relative.split(File::SEPARATOR).first)
      end

      named = profile_from_path(path)
      if named
        return false if store_file?(named) || (write && File.basename(path) == 'room.json')

        return profile_name.to_s.casecmp?(named)
      end

      true
    end

    def room_access(profile_name, path, write:)
      root = rooms_root
      prefix = "#{root}#{File::SEPARATOR}"
      return nil unless path == root || path.start_with?(prefix)
      return false if path == root

      room_name, file = path.delete_prefix(prefix).split(File::SEPARATOR)
      return false if room_name.nil? || file.nil?

      membership = room_membership(room_name, profile_name)
      return false unless membership

      case file
      when 'messages.jsonl' then membership[:visible]
      when 'policy.yml' then membership[:visible] && (!write || membership[:administrator])
      else false
      end
    end

    def hidden_rooms(profile_name)
      root = rooms_root
      return [] unless File.directory?(root)

      Dir.children(root).filter_map do |entry|
        dir = File.join(root, entry)
        next unless File.directory?(dir)

        membership = room_membership(entry, profile_name)
        dir unless membership && membership[:visible]
      end
    end

    def restricted(profile_name)
      agents = agents_dir
      ret = [
        agents,
        File.join(agents, 'sessions.json'),
        File.join(agents, 'sessions.json.lock'),
        *Dir.glob(File.join(agents, '.sessions-*'))
      ]
      ProfileStore.profiles.each do |profile|
        next if profile_name.to_s.casecmp?(profile.name)

        ret.concat(Dir.glob(File.join(profile.directory, '**', '*'), File::FNM_DOTMATCH))
      end
      hidden_rooms(profile_name).each do |dir|
        ret << dir
        ret.concat(Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH))
      end
      ret
    end

    def agents_dir
      resolve(File.join(ProfileStore.root, 'agents'), Workspace.project_dir)
    end

    def rooms_root
      resolve(Workspace.rooms_dir, Workspace.project_dir)
    end

    # Membership read straight from the room's profiles.json. Access cannot
    # depend on the Bus (that would close a require cycle), so the ladder lives
    # here as well - it is the same ladder Room enforces.
    def room_membership(room_name, profile_name)
      return nil if profile_name.to_s.empty?

      data = JSON.parse(File.read(File.join(rooms_root, room_name, 'profiles.json')))
      return nil unless data.is_a?(Hash)

      owner = data['owner'].to_s
      original = (!owner.empty? && owner.casecmp?(profile_name)) || ProfileStore::HUMAN_NAME.casecmp?(profile_name)
      admin = Array(data['admins']).any? { |name| name.to_s.casecmp?(profile_name) }
      involved = data['involved']
      member = involved.nil? || Array(involved).any? { |name| name.to_s.casecmp?(profile_name) }
      { administrator: original || admin, visible: original || admin || member }
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def under?(path, dir)
      path == dir || path.start_with?("#{dir}#{File::SEPARATOR}")
    end

    def shell_paths(command)
      Shellwords.shellsplit(command).select do |arg|
        arg.include?(File::SEPARATOR) ||
          arg.include?('\\') ||
          arg.start_with?('.', '~') ||
          arg.match?(/\A\$\{?HOME\}?/)
      end
    rescue ArgumentError
      []
    end

    def profile_from_path(path)
      match = %r{(?:\A|/)agents/([^/]+)(?:/|\z)}i.match(path.to_s.tr('\\', '/'))
      match && match[1]
    end

    def store_file?(path)
      name = path.to_s.split(/[\\\/]/).first.to_s.downcase
      name.start_with?('sessions.json', '.sessions-') || name == 'sessions.json.lock'
    end

    def deletes_protected?(command, dir)
      return false unless command.match?(/\b(?:rm|rmdir|shred)\b/i)

      shell_paths(command).map { |path| resolve(path, dir) }.any? do |path|
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
end
