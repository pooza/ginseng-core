# frozen_string_literal: true

module Ginseng
  class ConflictError < RequestError
    def status
      return 409
    end
  end
end
