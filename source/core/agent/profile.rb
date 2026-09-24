require_relative 'store'
require_relative 'permissions'

module Agent
  module Profile
    extend self

    def permissions
      Permissions
    end

    def get_profiles(root: Store::ROOT)
      Store.get_profiles(root: root)
    end

    def get_profile(session, root: Store::ROOT)
      Store.get_profile(session, root: root)
    end

    def set_profile(name, session:, root: Store::ROOT)
      Store.set_profile(session, name, root: root)
    end
  end
end
