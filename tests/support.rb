require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../source/config'
require_relative '../source/profile_store'
require_relative '../source/policy'
require_relative '../source/coord/bus'

module CoreTest
  def setup_core(config = {})
    @root = Dir.mktmpdir('autonom')
    @project = Dir.mktmpdir('autonom-project')
    @previous_project = ENV['DEVIN_PROJECT_DIR']
    @previous_root = ProfileStore.root
    ENV['DEVIN_PROJECT_DIR'] = @project
    ProfileStore.root = @root
    FileUtils.mkdir_p(File.join(@root, 'templates'))
    FileUtils.cp(File.join(ProfileStore::ROOT, 'templates', 'policy.yml'), File.join(@root, 'templates', 'policy.yml'))
    Policy.reset!
    write_config(config)
  end

  def teardown_core()
    ENV['DEVIN_PROJECT_DIR'] = @previous_project
    ProfileStore.root = @previous_root
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def write_config(values)
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), JSON.generate(values))
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
end
