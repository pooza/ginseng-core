# frozen_string_literal: true
module Ginseng
  class Gzip
    def self.compress(path)
      command = CommandLine.new(['gzip', '-f', path])
      command.exec
      return command.status
    end
  end
end
