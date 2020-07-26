module Ginseng
  class ValidateError < RequestError
    attr_reader :raw_message

    def status
      return 422
    end

    def initialize(message)
      @raw_message = message
      super
    end
  end
end
