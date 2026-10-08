require_relative '../profile_store'

require 'json'

module Coord
  class Membership
    def self.read(membership_path)
      new(JSON.parse(File.read(membership_path)))
    rescue SystemCallError, JSON::ParserError
      new(nil)
    end

    def initialize(data)
      @data = data.is_a?(Hash) ? data : nil
    end

    def owner
      @data && @data['owner']
    end

    def original_owner?(profile_name)
      owner_profile_names = [owner, ProfileStore::HUMAN_NAME].compact.map(&:to_s).reject(&:empty?).uniq
      named?(owner_profile_names, profile_name)
    end

    def admin?(profile_name)
      admin_profile_names = (@data && @data['admins']) || []
      named?(Array(admin_profile_names), profile_name)
    end

    def administrator?(profile_name)
      original_owner?(profile_name) || admin?(profile_name)
    end

    def involved?(profile_name)
      return false unless @data

      involved_profile_names = @data['involved']
      return true if involved_profile_names.nil?

      named?(Array(involved_profile_names), profile_name)
    end

    def visible?(profile_name)
      administrator?(profile_name) || involved?(profile_name)
    end

    private

    def named?(profile_names, profile_name)
      return false if profile_name.to_s.empty?

      profile_names.any? { |listed_name| listed_name.to_s.casecmp?(profile_name.to_s) }
    end
  end
end
