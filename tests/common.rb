require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../source/config'
require_relative '../source/profile_store'
require_relative '../source/coord/bus'

module CoreTest
  def setup_core(config = {})
    @root = Dir.mktmpdir('autonom')
    @project = Dir.mktmpdir('autonom-project')
    @previous_project = ENV['DEVIN_PROJECT_DIR']
    @previous_root = ProfileStore.root
    ENV['DEVIN_PROJECT_DIR'] = @project
    ProfileStore.root = @root
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

  def write_room(name, description = nil)
    path = File.join(@project, '.devin', 'autonom-coord', 'rooms', "#{name}.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, description ? "#{JSON.generate('description' => description)}\n" : '')
  end

  def room(name)
    Bus.rooms.find { |candidate| candidate.name == name }
  end

  def profile(name)
    ProfileStore.profile_by_name(name)
  end
end
