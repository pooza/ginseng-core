# frozen_string_literal: true

module Ginseng
  class NotFoundError < Error
    def status
      return 404
    end

    def broadcastable?
      return false
    end
  end
end
