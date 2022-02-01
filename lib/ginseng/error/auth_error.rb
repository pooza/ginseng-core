module Ginseng
  class AuthError < SecurityError
    def status
      return 403
    end
  end
end
