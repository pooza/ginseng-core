module Ginseng
  module Mockable
    include Package

    def save_mock(mock, options = {})
      return if environment_class.ci?
      return unless options[:mock]
      return unless environment_class.development?
      return unless environment_class.test?
      return if File.exist?(path = create_mock_path(options))
      File.write(path, Marshal.dump(mock))
      warn "#{__method__}: #{mock.class} #{File.basename(path)}"
    end

    def load_mock(options)
      return nil unless options[:error]
      raise options[:error] unless options[:mock]
      raise options[:error] unless environment_class.ci?
      raise options[:error] unless environment_class.test?
      mock = Marshal.load(File.read(path = create_mock_path(options))) # rubocop:disable Security/MarshalLoad
      warn "#{__method__}: #{mock.class} #{File.basename(path)}"
      return mock
    end

    def create_mock_path(options = {})
      path = File.join(
        environment_class.dir,
        'test/mock',
        options.merge(options[:mock]).to_json.adler32,
      )
      FileUtils.mkdir_p(File.dirname(path))
      return path
    end
  end
end
