require 'fileutils'
require 'json'

require_relative '../policy/format'
require_relative '../profile_store'
require_relative 'inbox'
require_relative 'membership'

# A room is a folder on the bus: its message stream and the profiles that may use it.
#
#   rooms/<name>/messages.jsonl   the stream (same shape as any inbox)
#   rooms/<name>/policy.yml       the room's restrict-only secondary policy
#   rooms/<name>/profiles.json    owner, admins, involved - private to the core
#
# Authority is a ladder: the original owner (the creator, and the human profile)
# manages the admins; the original owner and admins administer the room
# (policy, membership, deletion); involved profiles may read and write; nobody
# else knows the room exists.
class Room
  MESSAGES_FILE = 'messages.jsonl'
  POLICY_FILE = 'policy.yml'
  PROFILES_FILE = 'profiles.json'

  def self.create(room_name, room_dir, owner_profile_name:)
    FileUtils.mkdir_p(room_dir, mode: 0o700)
    raise ProfileStore::Error, 'Room directory must not be a symlink' if File.symlink?(room_dir)

    write_new(File.join(room_dir, MESSAGES_FILE), '')
    write_new(File.join(room_dir, POLICY_FILE), "rules: []\n")
    write_new(
      File.join(room_dir, PROFILES_FILE),
      JSON.generate('owner' => owner_profile_name, 'admins' => [], 'involved' => nil)
    )
    new(room_name, room_dir)
  end

  def self.write_new(file_path, contents)
    File.open(file_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
  end

  def initialize(room_name, room_dir)
    @name = room_name
    @directory = room_dir
  end

  attr_reader :name, :directory

  # The stream name the bus keys waits and cursors by.
  def stream
    "room:#{@name}"
  end

  def inbox
    @inbox ||= Inbox.new(stream, messages_path)
  end

  def messages_path
    File.join(@directory, MESSAGES_FILE)
  end

  def policy_path
    File.join(@directory, POLICY_FILE)
  end

  def profiles_path
    File.join(@directory, PROFILES_FILE)
  end

  def policy
    Policy.load(policy_path)
  end

  def owner
    membership.owner
  end

  def original_owner?(profile_name)
    membership.original_owner?(profile_name)
  end

  def admin?(profile_name)
    membership.admin?(profile_name)
  end

  def administrator?(profile_name)
    membership.administrator?(profile_name)
  end

  # `involved` nil is everyone in the clone; a list is exactly those profiles.
  # An unreadable membership file fails closed - nobody but the human owner.
  def involved?(profile_name)
    membership.involved?(profile_name)
  end

  def visible?(profile_name)
    membership.visible?(profile_name)
  end

  def add_admin(profile_name)
    update_profiles do |membership_data|
      membership_data['admins'] =
        (Array(membership_data['admins']) + [profile_name.to_s]).uniq { |admin| admin.downcase }
    end
  end

  def remove_admin(profile_name)
    update_profiles do |membership_data|
      membership_data['admins'] =
        Array(membership_data['admins']).reject { |admin| admin.casecmp?(profile_name.to_s) }
    end
  end

  def set_involved(profile_names)
    update_profiles do |membership_data|
      membership_data['involved'] = profile_names.nil? ? nil : Array(profile_names).map(&:to_s).reject(&:empty?).uniq
    end
  end

  private

  def membership
    @membership ||= Coord::Membership.read(profiles_path)
  end

  def update_profiles
    membership_path = profiles_path
    raise ProfileStore::Error, 'Room membership must not be a symlink' if File.symlink?(membership_path)

    File.open(membership_path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      membership_json = file.read
      membership_data = membership_json.strip.empty? ? {} : JSON.parse(membership_json)
      unless membership_data.is_a?(Hash)
        raise ProfileStore::Error, 'Room membership has an invalid format'
      end

      yield membership_data
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(membership_data))
      file.flush
      @membership = Coord::Membership.new(membership_data)
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update room membership: #{error.class}"
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Room membership has an invalid format'
  end
end
