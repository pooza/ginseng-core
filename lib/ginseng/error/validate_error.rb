# frozen_string_literal: true

module Ginseng
  class ValidateError < RequestError
    def status
      return 422
    end
  end
end
