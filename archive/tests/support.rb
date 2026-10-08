require 'fileutils'
require 'json'
require 'socket'
require 'tmpdir'

require_relative '../source/profile_store'
require_relative '../source/policy/access'
require_relative '../source/policy/format'
require_relative '../source/config'
require_relative '../source/coord/bus'

module CoreTest
  def setup_core()
    @root = Dir.mktmpdir('autonom')
    @project = Dir.mktmpdir('autonom-project')
    @previous_project = ENV['DEVIN_PROJECT_DIR']
    @previous_root = ProfileStore.root
    @previous_session_lock_dir = Profile.session_lock_dir
    ENV['DEVIN_PROJECT_DIR'] = @project
    ProfileStore.root = @root
    Profile.session_lock_dir = File.join(@root, 'session_locks')
    FileUtils.mkdir_p(File.dirname(Config.policy_path))
    FileUtils.cp(
      File.join(ProfileStore::ROOT, 'templates', 'policy.yml'),
      Config.policy_path
    )
  end

  def teardown_core()
    ENV['DEVIN_PROJECT_DIR'] = @previous_project
    ProfileStore.root = @previous_root
    Profile.session_lock_dir = @previous_session_lock_dir
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def write_room(name, owner: 'marlow', admins: [], involved: nil)
    dir = File.join(@project, '.devin', 'autonom-coord', 'rooms', name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'messages.jsonl'), '')
    File.write(File.join(dir, 'policy.yml'), "rules: []\n")
    File.write(
      File.join(dir, 'profiles.json'),
      JSON.generate('owner' => owner, 'admins' => admins, 'involved' => involved)
    )
    dir
  end

  def room(name)
    Bus.room_by_name(name)
  end

  def profile(name)
    ProfileStore.profile_by_name(name)
  end

  def with_online_session(session)
    FileUtils.mkdir_p(Profile.session_lock_dir)
    path = File.join(Profile.session_lock_dir, "#{session}.lock")
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      yield
    ensure
      file.flock(File::LOCK_UN)
    end
  end
end

# A mock provider for the gateway bridge: it answers one request and hands the
# parsed request body back so a test can assert what the bridge sent.
module MockProvider
  def with_env(overrides)
    previous = overrides.keys.to_h { |name| [name, ENV[name]] }
    overrides.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end

  def with_provider(content)
    server = TCPServer.new('127.0.0.1', 0)
    worker = Thread.new do
      socket = server.accept
      headers = []
      while (line = socket.gets) && line != "\r\n"
        headers << line
      end
      length = headers.find { |line| line.downcase.start_with?('content-length:') }.split(':', 2).last.to_i
      ret = JSON.parse(socket.read(length))
      body = JSON.generate(
        'id' => 'test-response',
        'object' => 'chat.completion',
        'created' => 0,
        'model' => 'test-model',
        'choices' => [{ 'index' => 0, 'message' => { 'role' => 'assistant', 'content' => content },
                        'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1, 'total_tokens' => 2 }
      )
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      ret
    ensure
      socket&.close
    end
    with_env(
      'AUTONOM_OPENROUTER_BASE_URL' => "http://127.0.0.1:#{server.addr[1]}/v1",
      'OPENROUTER_API_KEY' => 'test-key'
    ) do
      yield
      worker.value
    end
  ensure
    server&.close
    worker&.kill if worker&.alive?
  end
end
