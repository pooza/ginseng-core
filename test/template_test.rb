# frozen_string_literal: true

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
      assert_path_exist(@template.path)
    end

    def test_to_s
      @template[:output] = 1

      assert_equal("body1\n", @template.to_s)
      @template[:output] = 2

      assert_equal("body2\n", @template.to_s)
    end

    def test_params=
      assert_kind_of(Hash, @template.params)
      @template.params = {'output' => 3, 'body3' => 'body3'}

      assert_equal("body3\n", @template.to_s)
      @template.params = {output: 3, body3: 'body3!'}

      assert_equal("body3!\n", @template.to_s)
    end
  end
end
