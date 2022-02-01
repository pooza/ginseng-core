module Ginseng
  class AuthError < Error
    def status
      return 403
    end
  end
end
