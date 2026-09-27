require 'minitest/autorun'

require_relative 'common'
require_relative '../source/memory/memory'

class MemoryTest < Minitest::Test
  include CoreTest

  def setup()
    setup_bus()
  end

  def teardown()
    teardown_bus()
  end

  def test_a_missing_memory_is_empty()
    marlow = @bus.register('session-1', 'marlow')

    assert_empty marlow.memory.get()
  end

  def test_a_small_memory_is_returned_whole()
    marlow = @bus.register('session-1', 'marlow')
    write_memory(marlow, "# marlow - memory\n\nshort and whole\n")

    assert_equal "# marlow - memory\n\nshort and whole", marlow.memory.get()
  end

  def test_a_slice_keeps_identity_and_project_blocks()
    write_config('project' => 'jobs')
    marlow = @bus.register('session-1', 'marlow')
    write_memory(
      marlow,
      [
        '# marlow - memory',
        "## Now\n\nChecking the pricer.",
        "## 2026-09-01 - old\n\n#{"filler " * 400}",
        "## 2026-09-02 - jobs note [project:jobs]\n\njobs-specific detail",
        "## 2026-09-03 - recent\n\n#{"filler " * 400}"
      ].join("\n\n")
    )

    slice = marlow.memory.get(max_chars: 300)

    assert_includes slice, 'Checking the pricer.'
    assert_includes slice, 'jobs-specific detail'
    assert_operator slice.length, :<=, 300
  end

  # The layer is deliberately inert until the evals branch says otherwise.
  def test_recall_and_capture_do_nothing()
    marlow = @bus.register('session-1', 'marlow')
    write_memory(marlow, "# marlow - memory\n\nshort and whole\n")

    assert_empty marlow.memory.recall('anything')
    refute marlow.memory.capture('a durable lesson')
  end

  private

  def write_memory(profile, content)
    FileUtils.mkdir_p(File.join(profile.directory, 'memories'))
    File.write(File.join(profile.directory, 'memories', 'memory.md'), content)
  end
end
