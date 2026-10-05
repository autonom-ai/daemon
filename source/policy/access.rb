require 'shellwords'

require_relative '../coord/membership'
require_relative '../profile_store'
require_relative '../config'
require_relative 'format'

module Policy
  module Access
    extend self

    def permits?(profile_name, kind, path: nil, command: nil, base_dir: nil)
      return false unless Policy.workspace.permits?(kind, profile_name)
      return command_ok?(profile_name, command, base_dir) if kind == 'execute'

      path_ok?(profile_name, path, write: kind == 'write')
    end

    def search?(profile_name, file_path)
      return false unless path_ok?(profile_name, file_path, write: false)

      file_path = resolve(file_path, Config.project_dir)
      prefix = file_path.end_with?(File::SEPARATOR) ? file_path : "#{file_path}#{File::SEPARATOR}"
      return false if agents_dir.start_with?(prefix)
      hidden = hidden_rooms(profile_name).any? do |room_dir|
        room_dir == file_path || room_dir.start_with?(prefix)
      end
      return false if hidden

      true
    end

    def glob?(profile_name, pattern, file_path)
      return false unless pattern.is_a?(String) && !pattern.empty?
      return false unless path_ok?(profile_name, file_path, write: false)

      base_dir = resolve(file_path, Config.project_dir)
      glob = File.expand_path(pattern, base_dir)
      flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
      return false if restricted(profile_name).any? { |entry| File.fnmatch?(glob, entry, flags) }

      Dir.glob(glob, File::FNM_DOTMATCH).all? { |entry| path_ok?(profile_name, entry, write: false) }
    rescue ArgumentError, SystemCallError
      false
    end

    private

    def command_ok?(profile_name, command, base_dir)
      base_dir ||= Config.project_dir
      return false unless command.is_a?(String)
      return false unless path_ok?(profile_name, base_dir, write: false)
      return false if deletes_protected?(command, base_dir)

      shell_paths(command).all? do |entry|
        path_ok?(profile_name, entry, write: false) && path_ok?(profile_name, entry, write: true)
      end
    end

    def path_ok?(profile_name, file_path, write:)
      return false unless file_path.is_a?(String) && !file_path.empty?

      file_path = resolve(file_path, Config.project_dir)
      file_name = File.basename(file_path)
      return false if file_name == '.env' || file_name.start_with?('.env.')
      return false if file_path == resolve(Config.policy_path, Config.project_dir)

      room = room_access(profile_name, file_path, write: write)
      return room unless room.nil?

      agents = agents_dir
      if under?(file_path, agents)
        relative = file_path.delete_prefix("#{agents}#{File::SEPARATOR}")
        return false if relative.empty? || store_file?(relative)
        return false if write && File.basename(file_path) == 'policies.json'

        return profile_name.casecmp?(relative.split(File::SEPARATOR).first)
      end

      named_profile = profile_from_path(file_path)
      if named_profile
        return false if store_file?(named_profile) || (write && File.basename(file_path) == 'policies.json')

        return profile_name.casecmp?(named_profile)
      end

      true
    end

    def room_access(profile_name, file_path, write:)
      rooms_dir = rooms_root
      prefix = "#{rooms_dir}#{File::SEPARATOR}"
      return nil unless file_path == rooms_dir || file_path.start_with?(prefix)
      return false if file_path == rooms_dir

      room_name, file_name = file_path.delete_prefix(prefix).split(File::SEPARATOR)
      return false if room_name.nil? || file_name.nil?

      membership = Coord::Membership.read(File.join(rooms_dir, room_name, 'profiles.json'))
      case file_name
      when 'messages.jsonl' then membership.visible?(profile_name)
      when 'policy.yml' then membership.visible?(profile_name) &&
                              (!write || membership.administrator?(profile_name))
      else false
      end
    end

    def hidden_rooms(profile_name)
      rooms_dir = rooms_root
      return [] unless File.directory?(rooms_dir)

      Dir.children(rooms_dir).filter_map do |room_name|
        room_dir = File.join(rooms_dir, room_name)
        next unless File.directory?(room_dir)

        membership = Coord::Membership.read(File.join(room_dir, 'profiles.json'))
        room_dir unless membership.visible?(profile_name)
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
        next if profile_name.casecmp?(profile.name)

        ret.concat(Dir.glob(File.join(profile.directory, '**', '*'), File::FNM_DOTMATCH))
      end
      hidden_rooms(profile_name).each do |room_dir|
        ret << room_dir
        ret.concat(Dir.glob(File.join(room_dir, '**', '*'), File::FNM_DOTMATCH))
      end
      ret
    end

    def agents_dir
      resolve(File.join(ProfileStore.root, 'agents'), Config.project_dir)
    end

    def rooms_root
      resolve(Config.rooms_dir, Config.project_dir)
    end

    def under?(file_path, dir_path)
      file_path == dir_path || file_path.start_with?("#{dir_path}#{File::SEPARATOR}")
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

    def profile_from_path(file_path)
      match = %r{(?:\A|/)agents/([^/]+)(?:/|\z)}i.match(file_path.to_s.tr('\\', '/'))
      match && match[1]
    end

    def store_file?(file_name)
      base_name = file_name.to_s.split(/[\\\/]/).first.to_s.downcase
      base_name.start_with?('sessions.json', '.sessions-') || base_name == 'sessions.json.lock'
    end

    def deletes_protected?(command, base_dir)
      return false unless command.match?(/\b(?:rm|rmdir|shred)\b/i)

      shell_paths(command).map { |entry| resolve(entry, base_dir) }.any? do |entry|
        entry == resolve(Dir.home, base_dir) ||
          entry == resolve(File.join(ProfileStore.root, 'source'), base_dir) ||
          entry == resolve(File::SEPARATOR, base_dir)
      end
    end

    def resolve(file_path, base_dir)
      normalized_path = file_path.to_s
        .sub(/\A~(?=\/|\z)/, Dir.home)
        .gsub(/\$\{?HOME\}?/, Dir.home)
      normalized_path = File.expand_path(normalized_path, base_dir)
      probe = normalized_path
      suffix = []

      until File.exist?(probe) || File.symlink?(probe)
        parent = File.dirname(probe)
        break if parent == probe

        suffix.unshift(File.basename(probe))
        probe = parent
      end

      File.join(File.realpath(probe), *suffix)
    rescue SystemCallError
      normalized_path
    end
  end
end
