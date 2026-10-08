require_relative '../profile_store'
require_relative 'bus'
require_relative 'tools'

require 'json'

module Coord
  module Operations
    PROFILE_REQUIRED_TOOLS = %w[
      post_message
      read_messages
      wait_for_message
      list_rooms
      create_room
      delete_room
      set_room_involved
      add_room_admin
      remove_room_admin
    ].freeze

    include Tools

    def call_tool(params)
      tool = params['name'].to_s
      args = params['arguments'].is_a?(Hash) ? params['arguments'] : {}
      session_id = args['session_id']
      profile = nil
      if PROFILE_REQUIRED_TOOLS.include?(tool) ||
          (tool == 'get_profile_status' && args['name'].to_s.empty?)
        profile = ProfileStore.profile_by_session(session_id)
      end
      if PROFILE_REQUIRED_TOOLS.include?(tool) && !profile
        raise ProfileStore::Error, 'No profile is registered for this session; register one first'
      end

      ret = case tool
      when 'get_profiles'
        ProfileStore.profiles.map { |listed_profile| profile_entry(listed_profile) }
      when 'get_profile_status'
        get_profile_status(args, profile)
      when 'set_profile'
        profile_entry(ProfileStore.register_profile(args['name'], session_id))
      when 'post_message'
        post_message(args, profile)
      when 'read_messages'
        read_messages(args, profile)
      when 'wait_for_message'
        wait_for_message(args, profile)
      when 'list_rooms'
        list_rooms(profile)
      when 'create_room'
        create_room(args, profile)
      when 'delete_room'
        delete_room(args, profile)
      when 'set_room_involved'
        set_room_involved(args, profile)
      when 'add_room_admin'
        add_room_admin(args, profile)
      when 'remove_room_admin'
        remove_room_admin(args, profile)
      else
        return tool_error('Unknown profile tool')
      end

      {
        'content' => [{ 'type' => 'text', 'text' => JSON.generate(ret) }],
        'isError' => false
      }
    rescue ProfileStore::Error, Bus::Error => error
      tool_error(error.message)
    end

    private

    def post_message(args, sender_profile)
      text = args['text'].to_s
      raise ProfileStore::Error, 'A message needs text' if text.strip.empty?

      targets = ping_targets(args['ping'], sender_profile)
      if args['to'].to_s.empty?
        raise ProfileStore::Error, 'A room is required' if args['room'].to_s.empty?

        room = Bus.room_by_name(args['room'])
        raise ProfileStore::Error, "Unknown room: #{args['room']}" unless room && room.visible?(sender_profile.name)
        Bus.post(room, text, from: sender_profile)
        targets.each { |target_profile| Bus.ping(target_profile, text, from: sender_profile, room: room) }
        { 'result' => "Sent message to #{room.stream} with #{targets.length} pings" }
      else
        recipient_profile = ProfileStore.profile_by_name(args['to'])
        raise ProfileStore::Error, "Unknown profile: #{args['to']}" unless recipient_profile

        Bus.dm(recipient_profile, text, from: sender_profile)
        targets.each { |target_profile| Bus.ping(target_profile, text, from: sender_profile) }
        { 'result' => "Sent message to #{recipient_profile.name} with #{targets.length} pings" }
      end
    end

    def read_messages(args, profile)
      source, room = read_target(args, profile)
      read_stream(profile, source, room, limit(args))
    end

    # Wait behavior is somewhat complex but documented in Bus.
    def wait_for_message(args, profile)
      source, room = read_target(args, profile)
      raise ProfileStore::Error, 'Pings interrupt; they cannot be waited on' if source == 'pings'

      inbox = source == 'dms' ? Bus.dms_by_profile(profile) : room.inbox
      inbox.wait(profile, timeout: wait_timeout(args)) if inbox.unread(profile).empty?
      read_stream(profile, source, room, limit(args))
    end

    def list_rooms(profile)
      Bus.visible_rooms(profile).map { |room| room_entry(room, profile) }
    end

    def create_room(args, profile)
      room_entry(Bus.create_room(args['name'], owner_profile_name: profile.name), profile)
    end

    # Admin operations report a room as unknown to anyone who cannot perform
    # them, so a private room's existence is not leaked.
    def delete_room(args, profile)
      room = Bus.room_by_name(args['name'])
      raise ProfileStore::Error, "Unknown room: #{args['name']}" unless room && room.administrator?(profile.name)
      Bus.delete_room(room.name)
      { 'result' => "Deleted room #{room.stream}" }
    end

    def set_room_involved(args, profile)
      room = Bus.room_by_name(args['name'])
      raise ProfileStore::Error, "Unknown room: #{args['name']}" unless room && room.administrator?(profile.name)
      room.set_involved(involved_names(args['involved']))
      room_entry(room, profile)
    end

    def add_room_admin(args, profile)
      room = Bus.room_by_name(args['name'])
      raise ProfileStore::Error, "Unknown room: #{args['name']}" unless room && room.original_owner?(profile.name)
      target = ProfileStore.profile_by_name(args['profile'])
      raise ProfileStore::Error, "Unknown profile: #{args['profile']}" unless target

      room.add_admin(target.name)
      room_entry(room, profile)
    end

    def remove_room_admin(args, profile)
      room = Bus.room_by_name(args['name'])
      raise ProfileStore::Error, "Unknown room: #{args['name']}" unless room && room.original_owner?(profile.name)
      target = ProfileStore.profile_by_name(args['profile'])
      raise ProfileStore::Error, "Unknown profile: #{args['profile']}" unless target

      room.remove_admin(target.name)
      room_entry(room, profile)
    end

    def room_entry(room, profile)
      entries = room.inbox.messages
      {
        'name' => room.stream,
        'count' => entries.length,
        'unread' => room.inbox.unread(profile).length,
        'lastTs' => entries.last&.fetch('ts', nil)
      }
    end

    def get_profile_status(args, session_profile)
      requested_name = args['name'].to_s
      profile = requested_name.empty? ? session_profile : ProfileStore.profile_by_name(requested_name)
      raise ProfileStore::Error, "Unknown profile: #{requested_name}" if !requested_name.empty? && !profile

      profile && { 'name' => profile.name, 'session' => profile.session_id, 'online' => profile.online? }
    end

    def profile_entry(profile)
      profile && { 'name' => profile.name, 'directory' => profile.directory }
    end

    def read_target(args, profile)
      source = args['source'].to_s
      source = 'room' if source.empty?
      raise ProfileStore::Error, "Unknown source: #{source}" unless Tools::SOURCES.include?(source)
      return [source, nil] unless source == 'room'

      room_name = args['room']
      raise ProfileStore::Error, 'A room is required' if room_name.to_s.empty?

      room = Bus.room_by_name(room_name)
      raise ProfileStore::Error, "Unknown room: #{room_name}" unless room && room.visible?(profile.name)

      [source, room]
    end

    def involved_names(profile_names)
      return nil if profile_names.nil?
      raise ProfileStore::Error, 'Involved must be a list of profiles or null' unless profile_names.is_a?(Array)

      profile_names.map do |profile_name|
        profile = ProfileStore.profile_by_name(profile_name)
        raise ProfileStore::Error, "Unknown profile: #{profile_name}" unless profile

        profile.name
      end
    end

    def read_stream(profile, source, room, limit)
      case source
      when 'dms'
        { 'source' => 'dms', 'messages' => Bus.dms_by_profile(profile).read(profile, limit: limit) }
      when 'pings'
        { 'source' => 'pings', 'messages' => Bus.pings_by_profile(profile).read(profile) }
      else
        {
          'source' => 'room',
          'room' => room.name,
          'messages' => room.inbox.read(profile, limit: limit)
        }
      end
    end

    def wait_timeout(args)
      value = args['timeout']
      value.is_a?(Integer) ? value.clamp(1, Tools::MAX_WAIT) : Tools::DEFAULT_WAIT
    end

    def ping_targets(profile_names, sender_profile)
      return [] unless profile_names.is_a?(Array)

      target_profiles = profile_names.map do |profile_name|
        target_profile = ProfileStore.profile_by_name(profile_name)
        raise ProfileStore::Error, "Unknown profile to ping: #{profile_name}" unless target_profile

        target_profile
      end
      target_profiles.uniq { |target_profile| target_profile.name.downcase }
        .reject { |target_profile| target_profile.name.casecmp?(sender_profile.name) }
    end

    def limit(args)
      value = args['limit']
      value.is_a?(Integer) ? value.clamp(1, Tools::MAX_LIMIT) : Tools::DEFAULT_LIMIT
    end
  end
end
