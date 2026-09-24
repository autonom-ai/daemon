require_relative 'store'

require 'shellwords'

module Agent
  module Profile
    module Permissions
      extend self

      def can_set_profile?(name, session:, root: Store::ROOT)
        name = Store.normalize_name(name)
        profile = Store.get_profile(session, root: root)
        return true unless profile

        profile['name'].casecmp?(name)
      rescue Store::Error
        false
      end

      def can_read?(path, session: nil, root: Store::ROOT, dir: Dir.pwd)
        can_access?(path, session: session, root: root, dir: dir)
      end

      def can_write?(path, session: nil, root: Store::ROOT, dir: Dir.pwd)
        can_access?(path, session: session, root: root, dir: dir)
      end

      def can_search?(path, session: nil, root: Store::ROOT, dir: Dir.pwd)
        return false unless can_read?(path, session: session, root: root, dir: dir)

        path = resolve(path, dir)
        agents = resolve(File.join(root, 'agents'))
        prefix = path.end_with?(File::SEPARATOR) ? path : "#{path}#{File::SEPARATOR}"
        !agents.start_with?(prefix)
      end

      def can_glob?(pattern, path:, session: nil, root: Store::ROOT, dir: Dir.pwd)
        return false unless pattern.is_a?(String) && !pattern.empty?
        return false unless can_read?(path, session: session, root: root, dir: dir)

        base = resolve(path, dir)
        glob = File.expand_path(pattern, base)
        agents = resolve(File.join(root, 'agents'))
        restricted = [
          agents,
          File.join(agents, 'sessions.json'),
          File.join(agents, 'sessions.json.lock'),
          *Dir.glob(File.join(agents, '.sessions-*'))
        ]
        current = Store.get_profile(session, root: root)
        Store.get_profiles(root: root).each do |profile|
          next if current && profile['name'].casecmp?(current['name'])

          restricted.concat(Dir.glob(File.join(profile['directory'], '**', '*'), File::FNM_DOTMATCH))
        end

        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
        return false if restricted.any? { |path| File.fnmatch?(glob, path, flags) }

        Dir.glob(glob, File::FNM_DOTMATCH).all? do |path|
          can_read?(path, session: session, root: root, dir: base)
        end
      rescue ArgumentError, SystemCallError
        false
      end

      def can_exec?(cmd, session: nil, root: Store::ROOT, dir: Dir.pwd)
        return false unless cmd.is_a?(String)
        return false unless can_read?(dir, session: session, root: root)
        return false if deletes_protected?(cmd, root: root, dir: dir)

        shell_paths(cmd).all? do |path|
          can_read?(path, session: session, root: root, dir: dir) &&
            can_write?(path, session: session, root: root, dir: dir)
        end
      end

      private

      def can_access?(path, session:, root:, dir:)
        return false unless path.is_a?(String) && !path.empty?

        path = resolve(path, dir)
        root = resolve(root)
        name = File.basename(path)
        return false if name == '.env' || name.start_with?('.env.')

        agents = resolve(File.join(root, 'agents'))
        if path == agents || path.start_with?("#{agents}#{File::SEPARATOR}")
          relative = path.delete_prefix("#{agents}#{File::SEPARATOR}")
          return false if relative.empty? || store_file?(relative)

          name = relative.split(File::SEPARATOR).first
          profile = Store.get_profile(session, root: root)
          return profile && profile['name'].casecmp?(name)
        end

        name = profile_name(path)
        return true unless name
        return false if store_file?(name)

        profile = Store.get_profile(session, root: root)
        profile && profile['name'].casecmp?(name)
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

      def deletes_protected?(cmd, root:, dir:)
        return false unless cmd.match?(/\b(?:rm|rmdir|shred)\b/i)

        paths = shell_paths(cmd).map { |path| resolve(path, dir) }
        paths.any? do |path|
          path == resolve(Dir.home) ||
            path == resolve(File.join(root, 'source', 'core')) ||
            path == resolve(File::SEPARATOR)
        end
      end

      def resolve(path, dir = Dir.pwd)
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
end
