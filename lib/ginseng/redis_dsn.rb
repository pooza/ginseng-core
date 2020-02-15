module Ginseng
  class RedisDSN < URI
    def db
      return path.sub(%r{^/}, '').to_i
    end
  end
end
