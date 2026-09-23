require 'fileutils'
require 'json'
require 'securerandom'

module Agent
  module Store
    ROOT = File.expand_path('../../..', __dir__)
    NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/

    class Error < StandardError
    end

    extend self

    def get_profiles(root: ROOT)
      directory = agents_directory(root)
      return [] unless File.directory?(directory)
      raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(directory)

      Dir.children(directory).filter_map do |name|
        next unless valid_profile_name?(name)

        profile_directory = File.join(directory, name)
        next unless File.directory?(profile_directory) && !File.symlink?(profile_directory)

        { 'name' => name, 'directory' => File.realpath(profile_directory) }
      end.sort_by { |profile| profile['name'].downcase }
    end

    def get_profile(session_id, root: ROOT)
      return nil if session_id.nil? || session_id.to_s.empty?

      name = with_lock(root, File::LOCK_SH) do
        read_sessions(root)[validate_session_id(session_id)]
      end
      return nil unless name

      profile = find_profile(name, root: root)
      raise Error, 'The registered profile no longer exists' unless profile

      profile
    end

    def set_profile(session_id, name, root: ROOT)
      session_key = validate_session_id(session_id)
      requested_name = normalize_profile_name(name)

      with_lock(root, File::LOCK_EX) do
        sessions = read_sessions(root)
        registered_name = sessions[session_key]

        if registered_name
          registered = find_profile(registered_name, root: root)
          raise Error, 'The registered profile no longer exists' unless registered
          unless registered['name'].casecmp?(requested_name)
            raise Error, 'A session profile cannot be changed after registration'
          end

          next registered
        end

        profile = find_profile(requested_name, root: root) ||
          create_profile(requested_name.downcase, root: root)
        sessions[session_key] = profile['name']
        write_sessions(sessions, root: root)
        profile
      end
    end

    def migrate_memories!(root: ROOT)
      get_profiles(root: root).each do |profile|
        profile_directory = profile['directory']
        memories_directory = File.join(profile_directory, 'memories')
        FileUtils.mkdir_p(memories_directory)
        memory_files = Dir.glob(File.join(profile_directory, '*.md'), File::FNM_DOTMATCH).reject do |file|
          File.basename(file).casecmp?('identity.md')
        end
        next if memory_files.empty?
        memory_files.each do |source|
          destination = File.join(memories_directory, File.basename(source))
          if File.exist?(destination)
            unless FileUtils.compare_file(source, destination)
              raise Error, "Memory destination already exists: #{File.basename(destination)}"
            end

            File.delete(source)
          else
            FileUtils.mv(source, destination)
          end
        end
      end
    end

    def valid_profile_name?(name)
      name.is_a?(String) && NAME_PATTERN.match?(name)
    end

    def normalize_profile_name(name)
      normalized = name.to_s.strip
      raise Error, 'Invalid profile name' unless valid_profile_name?(normalized)

      normalized
    end

    private

    def agents_directory(root)
      File.join(File.expand_path(root), 'agents')
    end

    def find_profile(name, root: ROOT)
      matches = get_profiles(root: root).select { |profile| profile['name'].casecmp?(name.to_s) }
      raise Error, 'Profile names must be unique without regard to case' if matches.length > 1

      matches.first
    end

    def create_profile(name, root: ROOT)
      directory = agents_directory(root)
      FileUtils.mkdir_p(directory)
      raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(directory)

      profile_directory = File.join(directory, name)
      FileUtils.mkdir(profile_directory, mode: 0o700)
      FileUtils.mkdir(File.join(profile_directory, 'memories'), mode: 0o700)
      File.open(
        File.join(profile_directory, 'identity.md'),
        File::WRONLY | File::CREAT | File::EXCL,
        0o600
      ) do |file|
        file.write("---\nname: #{name}\ndisplayName: #{name}\n---\n\n# #{name}\n")
      end
      { 'name' => name, 'directory' => File.realpath(profile_directory) }
    rescue SystemCallError => error
      raise Error, "Could not create profile: #{error.class}"
    end

    def validate_session_id(session_id)
      value = session_id.to_s
      raise Error, 'A valid session ID is required' if value.empty? || value.length > 512 || value.include?("\0")

      value
    end

    def with_lock(root, mode)
      directory = agents_directory(root)
      FileUtils.mkdir_p(directory)
      raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(directory)

      lock_path = File.join(directory, 'sessions.json.lock')
      raise Error, 'Session lock must not be a symlink' if File.symlink?(lock_path)

      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        File.chmod(0o600, lock_path)
        file.flock(mode)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    rescue SystemCallError => error
      raise Error, "Could not lock session mappings: #{error.class}"
    end

    def read_sessions(root)
      path = File.join(agents_directory(root), 'sessions.json')
      return {} unless File.exist?(path)
      raise Error, 'Session mapping file must not be a symlink' if File.symlink?(path)

      File.chmod(0o600, path)
      sessions = JSON.parse(File.read(path))
      unless sessions.is_a?(Hash) && sessions.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
        raise Error, 'Session mapping file has an invalid format'
      end

      sessions
    rescue JSON::ParserError
      raise Error, 'Session mapping file contains invalid JSON'
    rescue SystemCallError => error
      raise Error, "Could not read session mappings: #{error.class}"
    end

    def write_sessions(sessions, root: ROOT)
      directory = agents_directory(root)
      path = File.join(directory, 'sessions.json')
      temporary_path = File.join(directory, ".sessions-#{Process.pid}-#{SecureRandom.hex(8)}.tmp")
      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(sessions))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(temporary_path, path)
    rescue SystemCallError => error
      raise Error, "Could not save session mapping: #{error.class}"
    ensure
      File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
    end
  end
end
