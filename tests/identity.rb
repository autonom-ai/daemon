require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/agent/identity'

class IdentityTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agent-coord')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_identity_frontmatter_is_metadata_and_the_body_is_the_person
    write_identity(
      'marlow',
      "---\nname: marlow\ndisplayName: Marlow\ncolor: \"#6d9ce8\"\n---\n\n" \
      "I read the kill columns.\nRule: read the room first.\n"
    )

    identity = Agent::Identity.get('marlow', root: @root)

    assert_equal 'Marlow', identity['display_name']
    assert_equal '#6d9ce8', identity['color']
    assert_includes identity['personality'], 'I read the kill columns.'
    assert_includes identity['personality'], 'Rule: read the room first.'
  end

  def test_missing_identity_is_nil
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren'))

    assert_nil Agent::Identity.get('wren', root: @root)
    assert_nil Agent::Identity.get('nobody', root: @root)
  end

  def test_priors_digest_interests_and_skip_self
    write_identity('wren', "---\nname: wren\ndisplayName: Wren\n---\n\n## Interests\n\nembeddings, search quality\n\n## Disinterests\n\nresume formatting\n")
    write_identity('marlow', "---\nname: marlow\ndisplayName: Marlow\n---\n\n## Voice\n\nblunt\n")

    priors = Agent::Identity.priors(root: @root, skip: 'marlow')

    assert_equal 1, priors.length
    assert_includes priors.first, 'Wren:'
    assert_includes priors.first, 'embeddings, search quality'
    assert_includes priors.first, 'resume formatting'
    refute_includes priors.join, 'blunt'
  end

  private

  def write_identity(name, content)
    dir = File.join(@root, 'agents', name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'identity.md'), content)
  end

end
