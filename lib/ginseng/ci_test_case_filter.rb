module Ginseng
  class CiTestCaseFilter < TestCaseFilter
    include Package

    def active?
      return environment_class.ci?
    end
  end
end
