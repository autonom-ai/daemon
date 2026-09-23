require_relative 'store'

require 'shellwords'

module Agent
  module Profile
    extend self

    def get_profiles(root: Store::ROOT)
      Store.get_profiles(root: root)
    end

    def get_profile(session_id, root: Store::ROOT)
      Store.get_profile(session_id, root: root)
    end

    def set_profile(name, session_id:, root: Store::ROOT)
      Store.set_profile(session_id, name, root: root)
    end

    def can_set_profile?(name, session_id:, root: Store::ROOT)
      requested_name = Store.normalize_profile_name(name)
      profile = get_profile(session_id, root: root)
      return true unless profile

      profile['name'].casecmp?(requested_name)
    rescue Store::Error
      false
    end

    def can_read?(path, session_id: nil, root: Store::ROOT, working_directory: Dir.pwd)
      can_access?(path, session_id: session_id, root: root, working_directory: working_directory)
    end

    def can_write?(path, session_id: nil, root: Store::ROOT, working_directory: Dir.pwd)
      can_access?(path, session_id: session_id, root: root, working_directory: working_directory)
    end

    def can_search?(path, session_id: nil, root: Store::ROOT, working_directory: Dir.pwd)
      return false unless can_read?(path, session_id: session_id, root: root, working_directory: working_directory)

      resolved_path = canonical_path(path, working_directory)
      agents_path = canonical_path(File.join(root, 'agents'))
      prefix = resolved_path.end_with?(File::SEPARATOR) ? resolved_path : "#{resolved_path}#{File::SEPARATOR}"
      !agents_path.start_with?(prefix)
    end

    def can_glob?(pattern, path:, session_id: nil, root: Store::ROOT, working_directory: Dir.pwd)
      return false unless pattern.is_a?(String) && !pattern.empty?
      return false unless can_read?(path, session_id: session_id, root: root, working_directory: working_directory)

      base = canonical_path(path, working_directory)
      absolute_pattern = File.expand_path(pattern, base)
      agents_path = canonical_path(File.join(root, 'agents'))
      restricted_paths = [
        agents_path,
        File.join(agents_path, 'sessions.json'),
        File.join(agents_path, 'sessions.json.lock'),
        *Dir.glob(File.join(agents_path, '.sessions-*'))
      ]
      current_profile = get_profile(session_id, root: root)
      Store.get_profiles(root: root).each do |profile|
        next if current_profile && profile['name'].casecmp?(current_profile['name'])

        restricted_paths.concat(Dir.glob(File.join(profile['directory'], '**', '*'), File::FNM_DOTMATCH))
      end

      flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
      return false if restricted_paths.any? { |target| File.fnmatch?(absolute_pattern, target, flags) }

      Dir.glob(absolute_pattern, File::FNM_DOTMATCH).all? do |match|
        can_read?(match, session_id: session_id, root: root, working_directory: base)
      end
    rescue ArgumentError, SystemCallError
      false
    end

    def can_exec?(command, session_id: nil, root: Store::ROOT, working_directory: Dir.pwd)
      return false unless command.is_a?(String)
      return false unless can_read?(
        working_directory,
        session_id: session_id,
        root: root
      )
      return false if deletes_protected_directory?(command, root: root, working_directory: working_directory)

      shell_paths(command).all? do |path|
        can_read?(path, session_id: session_id, root: root, working_directory: working_directory) &&
          can_write?(path, session_id: session_id, root: root, working_directory: working_directory)
      end
    end

    private

    def can_access?(path, session_id:, root:, working_directory:)
      return false unless path.is_a?(String) && !path.empty?

      resolved_path = canonical_path(path, working_directory)
      root_path = canonical_path(File.expand_path(root))
      basename = File.basename(resolved_path)
      return false if basename == '.env' || basename.start_with?('.env.')

      agents_path = canonical_path(File.join(root_path, 'agents'))
      if resolved_path == agents_path || resolved_path.start_with?("#{agents_path}#{File::SEPARATOR}")
        relative_path = resolved_path.delete_prefix("#{agents_path}#{File::SEPARATOR}")
        return false if relative_path.empty? || protected_store_file?(relative_path)

        profile_name = relative_path.split(File::SEPARATOR).first
        profile = get_profile(session_id, root: root)
        return profile && profile['name'].casecmp?(profile_name)
      end

      profile_name = profile_in_path(path)
      return true unless profile_name
      return false if protected_store_file?(profile_name)

      profile = get_profile(session_id, root: root)
      profile && profile['name'].casecmp?(profile_name)
    end

    def shell_paths(command)
      Shellwords.shellsplit(command).select do |token|
        token.include?(File::SEPARATOR) ||
          token.include?('\\') ||
          token.start_with?('.', '~') ||
          token.match?(/\A\$\{?HOME\}?/)
      end
    rescue ArgumentError
      []
    end

    def profile_in_path(path)
      normalized_path = path.to_s.tr('\\', '/')
      match = %r{(?:\A|/)agents/([^/]+)(?:/|\z)}i.match(normalized_path)
      match && match[1]
    end

    def protected_store_file?(relative_path)
      first = relative_path.to_s.split(/[\\\/]/).first.to_s.downcase
      first.start_with?('sessions.json', '.sessions-') || first == 'sessions.json.lock'
    end

    def deletes_protected_directory?(command, root:, working_directory:)
      return false unless command.match?(/\b(?:rm|rmdir|shred)\b/i)

      paths = shell_paths(command).map { |path| canonical_path(path, working_directory) }
      home_path = canonical_path(Dir.home)
      core_path = canonical_path(File.join(root, 'source', 'core'))
      root_path = canonical_path(File::SEPARATOR)
      paths.any? { |path| path == home_path || path == core_path || path == root_path }
    end

    def canonical_path(path, working_directory = Dir.pwd)
      expanded = path.to_s
        .sub(/\A~(?=\/|\z)/, Dir.home)
        .gsub(/\$\{?HOME\}?/, Dir.home)
      expanded = File.expand_path(expanded, working_directory)
      probe = expanded
      suffix = []

      until File.exist?(probe) || File.symlink?(probe)
        parent = File.dirname(probe)
        break if parent == probe

        suffix.unshift(File.basename(probe))
        probe = parent
      end

      File.join(File.realpath(probe), *suffix)
    rescue SystemCallError
      expanded
    end
  end
end
