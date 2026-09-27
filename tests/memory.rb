require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/memory/memory'

class MemoryTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('autonom')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_missing_memory_is_empty
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren'))

    assert_empty Memory.get('wren', 'jobs', root: @root)
    assert_empty Memory.get('nobody', 'jobs', root: @root)
  end

  def test_slice_keeps_identity_and_project_blocks
    write_memory(
      'marlow',
      [
        '# marlow - memory',
        "## Now\n\nChecking the pricer.",
        "## 2026-09-01 - old\n\n#{"filler " * 400}",
        "## 2026-09-02 - jobs note [project:jobs]\n\njobs-specific detail",
        "## 2026-09-03 - recent\n\n#{"filler " * 400}"
      ].join("\n\n")
    )

    slice = Memory.get('marlow', 'jobs', max_chars: 300, root: @root)

    assert_includes slice, 'Checking the pricer.'
    assert_includes slice, 'jobs-specific detail'
    assert_operator slice.length, :<=, 300
  end

  def test_small_memory_is_returned_whole
    write_memory('marlow', "# marlow - memory\n\nshort and whole\n")

    assert_equal "# marlow - memory\n\nshort and whole", Memory.get('marlow', 'jobs', root: @root)
  end

  # The layer is deliberately inert until the evals branch says otherwise.
  def test_recall_and_capture_do_nothing
    write_memory('marlow', "# marlow - memory\n\nshort and whole\n")

    assert_empty Memory.recall('marlow', 'anything', project: 'jobs', root: @root)
    refute Memory.capture('marlow', 'a durable lesson', root: @root)
  end

  private

  def write_memory(name, content)
    dir = File.join(@root, 'agents', name, 'memories')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'memory.md'), content)
  end
end
