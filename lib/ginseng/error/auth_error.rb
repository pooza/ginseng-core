# frozen_string_literal: true

module Ginseng
  class AuthError < Error
    def status
      return 403
    end
  end
end
