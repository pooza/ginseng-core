# frozen_string_literal: true

module Ginseng
  class RequestError < Error
    def status
      return 400
    end
  end
end
