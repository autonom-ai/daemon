require 'fileutils'
require 'json'

module Bus
  class Error < StandardError
  end

  module StreamStore
    CURSORS_FILE = 'cursors.json'

    extend self

    def read(file_path)
      return [] unless File.exist?(file_path)

      File.read(file_path).lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError => error
      raise Bus::Error, "Could not read chat stream: #{error.class}"
    end

    def append(file_path, entry)
      FileUtils.mkdir_p(File.dirname(file_path), mode: 0o700)
      File.open(file_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.write("#{JSON.generate(entry)}\n")
      end
    rescue SystemCallError => error
      raise Bus::Error, "Could not append to chat stream: #{error.class}"
    end

    # A stream file must not be a symlink, or an append would land wherever the
    # link points.
    def path(stream_dir, file_name)
      raise Bus::Error, 'Stream directory must not be a symlink' if File.symlink?(stream_dir)

      file_path = File.join(stream_dir, file_name)
      raise Bus::Error, 'Stream file must not be a symlink' if File.symlink?(file_path)

      file_path
    end

    def cursor(profile, stream_name)
      cursors(profile)[stream_name.to_s].to_i
    end

    def advance_cursor(profile, stream_name, count)
      cursor_path = cursors_path(profile)
      FileUtils.mkdir_p(File.dirname(cursor_path), mode: 0o700)
      File.open(cursor_path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        current = parse_cursors(file.read)
        next if current[stream_name.to_s].to_i >= count

        current[stream_name.to_s] = count
        file.rewind
        file.truncate(0)
        file.write(JSON.generate(current))
        file.flush
      ensure
        file.flock(File::LOCK_UN)
      end
    rescue SystemCallError => error
      raise Bus::Error, "Could not update the read cursor: #{error.class}"
    end

    # Unread entries, and reading advances the cursor: a stream is delivered
    # once. A first read starts with the newest `limit` entries instead of the
    # whole backlog.
    def read_stream(profile, stream_name, entries, limit: nil)
      seen = cursor(profile, stream_name)
      unread = seen.zero? && limit ? entries.last(limit) : entries.drop(seen)
      advance_cursor(profile, stream_name, entries.length)
      unread
    end

    private

    def cursors(profile)
      cursor_path = cursors_path(profile)
      File.exist?(cursor_path) ? parse_cursors(File.read(cursor_path)) : {}
    rescue SystemCallError => error
      raise Bus::Error, "Could not read the read cursor: #{error.class}"
    end

    def cursors_path(profile)
      path(profile.directory, CURSORS_FILE)
    end

    def parse_cursors(cursors_json)
      parsed = cursors_json.strip.empty? ? {} : JSON.parse(cursors_json)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
