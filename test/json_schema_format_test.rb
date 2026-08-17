# frozen_string_literal: true

module Ginseng
  # format: uri が実際に不正な値を弾くこと (#516)。
  #
  # 上流の json-schema は Addressable でパースできるかしか見ないので、この検証を
  # 差し替えないと `これはURLではない` すら通る。「書いてあるのに何も弾かない」を
  # 防ぐのが目的なので、正テスト（実際に落ちる）を必ず持つ。
  class JSONSchemaFormatTest < TestCase
    SCHEMA = {
      'type' => 'object',
      'properties' => {'v' => {'type' => 'string', 'format' => 'uri'}},
    }.freeze

    def errors(value)
      return JSON::Validator.fully_validate(SCHEMA, {'v' => value})
    end

    # ⚠ ここが本体。上流の実装ではすべて通っていた。
    def test_rejects_relative_and_malformed
      ['これはURLではない', 'has space here', 'precure.ml', '/path/only', '', '::::'].each do |value|
        assert_not_empty(errors(value), "#{value.inspect} が通ってしまう")
      end
    end

    def test_accepts_absolute_uri
      [
        'https://precure.ml',
        'http://example.com/a?b=c#d',
        'https://例え.テスト/日本語',
        'mailto:nobody@example.com',
      ].each do |value|
        assert_empty(errors(value), "#{value.inspect} が弾かれてしまう")
      end
    end

    # ⚠⚠ スキームを http(s) に限定しない。モロヘイヤが dsn に format: uri を
    # 使っているので、ここを狭めると本番の設定が落ちる。
    def test_accepts_non_http_schemes
      ['postgres://user:pw@db:5432/name', 'redis://127.0.0.1:6379/0', 'ftp://example.com'].each do |value|
        assert_empty(errors(value), "#{value.inspect} が弾かれてしまう")
      end
    end

    # ⚠ スキーム名の typo は URI としては妥当なので、ここでは止まらない。
    # 「http でなければならない」はアプリ側の要件で、schema の pattern で書く
    # (pooza/makoto2#35)。この線引きを崩さないための negative test。
    def test_does_not_pretend_to_validate_scheme_names
      assert_empty(errors('htps://precure.ml'))
      assert_not_empty(
        JSON::Validator.fully_validate(
          {'type' => 'object', 'properties' => {'v' => {'type' => 'string', 'pattern' => '^https?://'}}},
          {'v' => 'htps://precure.ml'},
        ),
      )
    end

    # 型の誤りは type の担当。format が二重に鳴ると 1 つの誤りが 2 行になる。
    def test_leaves_non_strings_to_type
      messages = errors(1)

      assert_not_empty(messages)
      assert_empty(messages.grep(/absolute URI/))
    end
  end
end
