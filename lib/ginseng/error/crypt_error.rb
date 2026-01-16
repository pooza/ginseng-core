# frozen_string_literal: true
module Ginseng
  class CryptError < Error
    def status
      return 403
    end
  end
end
