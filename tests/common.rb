require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../source/config'
require_relative '../source/profile_store'
require_relative '../source/coord/bus'

# Shared setup for the core's tests: a workspace and a store in temporary
# directories, and the bus over them.
module CoreTest
  def setup_bus(config = {})
    @root = Dir.mktmpdir('autonom')
    @project = Dir.mktmpdir('autonom-project')
    @store = ProfileStore.new(@root)
    write_config(config)
  end

  def teardown_bus()
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def write_config(values)
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), JSON.generate(values))
    @bus = Bus.new(config: Config.load(@project), store: @store)
  end
end
