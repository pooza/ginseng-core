module Ginseng
  class WindowsTestCaseFilter < TestCaseFilter
    include Package

    def active?
      return environment_class.win?
    end
  end
end
