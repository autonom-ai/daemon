require 'minitest/autorun'

require_relative 'support'
require_relative '../source/identity'

class IdentityTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
  end

  def teardown()
    teardown_core()
  end

  def test_frontmatter_is_metadata_and_the_body_is_the_person()
    write_identity(
      @marlow,
      "---\nname: marlow\ndisplayName: Marlow\ncolor: \"#6d9ce8\"\n---\n\n" \
      "I read the kill columns.\nRule: read the room first.\n"
    )

    identity = @marlow.identity

    assert_equal 'Marlow', identity.display_name
    assert_equal '#6d9ce8', identity.get()['color']
    assert_includes identity.get()['personality'], 'I read the kill columns.'
    assert_includes identity.get()['personality'], 'Rule: read the room first.'
  end

  def test_a_missing_identity_falls_back_to_the_profile_name()
    File.unlink(File.join(@marlow.directory, 'identity.md'))

    assert_nil @marlow.identity.get()
    assert_equal 'marlow', @marlow.identity.display_name
  end

  def test_priors_digest_interests_and_skip_self()
    wren = ProfileStore.register_profile('wren', 'session-2')
    write_identity(
      wren,
      "---\ndisplayName: Wren\n---\n\n## Interests\n\nembeddings, search quality\n\n" \
      "## Disinterests\n\nresume formatting\n"
    )
    write_identity(@marlow, "---\ndisplayName: Marlow\n---\n\n## Voice\n\nblunt\n")

    priors = Identity.priors(ProfileStore.profiles, skip_profile_name: 'marlow')

    assert_equal 1, priors.length
    assert_includes priors.first, 'Wren:'
    assert_includes priors.first, 'embeddings, search quality'
    assert_includes priors.first, 'resume formatting'
    refute_includes priors.join, 'blunt'
  end

  private

  def write_identity(profile, content)
    File.write(File.join(profile.directory, 'identity.md'), content)
  end
end
