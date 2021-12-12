module Ginseng
  class TemplateTest < TestCase
    def setup
      @template = Template.new('test')
      @template[:body1] = 'body1'
      @template[:body2] = 'body2'
    end

    def test_template_error
      assert_raise(RenderError) do
        Template.new('not_exist')
      end
    end

    def test_path
      assert(File.exist?(@template.path))
    end

    def test_to_s
      @template[:output] = 1
      assert_equal(@template.to_s, "body1\n")
      @template[:output] = 2
      assert_equal(@template.to_s, "body2\n")
    end

    def test_params=
      assert_kind_of(Hash, @template.params)
      @template.params = {'output' => 3, 'body3' => 'body3'}
      assert_equal(@template.to_s, "body3\n")
      @template.params = {output: 3, body3: 'body3!'}
      assert_equal(@template.to_s, "body3!\n")
    end
  end
end
