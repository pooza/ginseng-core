module Ginseng
  class ValidateError < RequestError
    def status
      return 422
    end
  end
end
