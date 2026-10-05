require 'fileutils'
require 'json'
require 'securerandom'

require_relative 'profile'

module ProfileStore
  ROOT = File.expand_path('..', __dir__)
  NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  SESSIONS_FILE = 'sessions.json'
  HUMAN_NAME = 'human'

  class Error < StandardError
  end

  extend self

  def root
    @root ||= ROOT
  end

  def root=(root_dir)
    @root = File.expand_path(root_dir)
  end

  def profiles
    ensure_human
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(agents_dir)

    Dir.children(agents_dir).filter_map do |profile_name|
      next unless valid_name?(profile_name)

      profile_dir = File.join(agents_dir, profile_name)
      next unless File.directory?(profile_dir) && !File.symlink?(profile_dir)

      Profile.new(profile_name, File.realpath(profile_dir))
    end.sort_by { |profile| profile.name.downcase }
  end

  def profile_by_session(session_id)
    return nil if session_id.to_s.empty?

    with_lock(File::LOCK_SH) do
      profile_name = read_sessions[session_id]
      next nil unless profile_name

      profile = profile_by_name(profile_name) || raise(Error, 'The registered profile no longer exists')
      current_session_id = profile.session_id
      current_session_id.nil? || current_session_id == session_id ? profile : nil
    end
  end

  def profile_by_name(profile_name)
    matches = profiles.select { |profile| profile.name.casecmp?(profile_name.to_s) }
    raise Error, 'Profile names must be unique without regard to case' if matches.length > 1

    matches.first
  end

  def register_profile(profile_name, session_id)
    raise Error, 'A valid session ID is required' if session_id.to_s.empty?

    profile_name = profile_name.to_s.strip
    raise Error, 'Invalid profile name' unless valid_name?(profile_name)
    raise Error, 'The human profile cannot be registered to an agent session' if profile_name.casecmp?(HUMAN_NAME)

    with_lock(File::LOCK_EX) do
      sessions = read_sessions
      mapped_profile_name = sessions[session_id]
      existing_profile = mapped_profile_name ? profile_by_name(mapped_profile_name) : profile_by_name(profile_name)
      raise Error, 'The registered profile no longer exists' if mapped_profile_name && !existing_profile
      if mapped_profile_name && !existing_profile.name.casecmp?(profile_name)
        raise Error, 'A session profile cannot be changed after registration'
      end

      existing_profile ||= create(profile_name.downcase)
      current_session_id = existing_profile.session_id
      if current_session_id && current_session_id != session_id && existing_profile.online?
        raise Error, 'The profile is already mapped to an online session'
      end

      existing_profile.bind_session(session_id) unless current_session_id == session_id
      sessions[session_id] = existing_profile.name
      write_sessions(sessions) unless mapped_profile_name && current_session_id == session_id
      existing_profile
    end
  end

  def valid_name?(profile_name)
    profile_name.is_a?(String) && NAME_PATTERN.match?(profile_name)
  end

  private

  def agents_dir
    File.join(root, 'agents')
  end

  def ensure_human
    human_profile_dir = File.join(agents_dir, HUMAN_NAME)
    return if File.directory?(human_profile_dir) && !File.symlink?(human_profile_dir)

    create(HUMAN_NAME)
  end

  def create(profile_name)
    FileUtils.mkdir_p(agents_dir)
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(agents_dir)

    profile_dir = File.join(agents_dir, profile_name)
    FileUtils.mkdir(profile_dir, mode: 0o700)
    File.open(
      File.join(profile_dir, 'identity.md'),
      File::WRONLY | File::CREAT | File::EXCL,
      0o600
    ) do |file|
      file.write("---\nname: #{profile_name}\ndisplayName: #{profile_name}\n---\n\n# #{profile_name}\n")
    end
    Profile.new(profile_name, File.realpath(profile_dir))
  rescue Errno::EEXIST
    raise Error, 'Profile already exists' unless profile_name == HUMAN_NAME && File.directory?(profile_dir)
    raise Error, 'Human profile must not be a symlink' if File.symlink?(profile_dir)

    Profile.new(profile_name, File.realpath(profile_dir))
  rescue SystemCallError => error
    raise Error, "Could not create profile: #{error.class}"
  end

  def with_lock(mode)
    FileUtils.mkdir_p(agents_dir)
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(agents_dir)

    session_lock_path = File.join(agents_dir, "#{SESSIONS_FILE}.lock")
    raise Error, 'Session lock must not be a symlink' if File.symlink?(session_lock_path)

    File.open(session_lock_path, File::RDWR | File::CREAT, 0o600) do |file|
      File.chmod(0o600, session_lock_path)
      file.flock(mode)
      yield
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise Error, "Could not lock session mappings: #{error.class}"
  end

  def read_sessions()
    sessions_path = File.join(agents_dir, SESSIONS_FILE)
    return {} unless File.exist?(sessions_path)
    raise Error, 'Session mapping file must not be a symlink' if File.symlink?(sessions_path)

    File.chmod(0o600, sessions_path)
    sessions = JSON.parse(File.read(sessions_path))
    unless sessions.is_a?(Hash) &&
        sessions.all? { |session_id, profile_name| session_id.is_a?(String) && profile_name.is_a?(String) }
      raise Error, 'Session mapping file has an invalid format'
    end

    sessions
  rescue JSON::ParserError
    raise Error, 'Session mapping file contains invalid JSON'
  rescue SystemCallError => error
    raise Error, "Could not read session mappings: #{error.class}"
  end

  def write_sessions(sessions)
    sessions_path = File.join(agents_dir, SESSIONS_FILE)
    temp_path = File.join(agents_dir, ".sessions-#{Process.pid}-#{SecureRandom.hex(8)}.tmp")
    File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(sessions))
      file.write("\n")
      file.flush
      file.fsync
    end
    File.rename(temp_path, sessions_path)
  rescue SystemCallError => error
    raise Error, "Could not save session mapping: #{error.class}"
  ensure
    File.unlink(temp_path) if temp_path && File.exist?(temp_path)
  end
end
