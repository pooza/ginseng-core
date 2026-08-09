# frozen_string_literal: true

module Ginseng
  class LoggerTest < TestCase
    def disable?
      return true if environment_class.win?
      return false
    end

    def setup
      @logger = Logger.new
    end

    def test_new
      assert_kind_of(Logger, @logger)
      assert_kind_of(Syslog::Logger, @logger)
    end

    def test_create_message
      assert_kind_of(Hash, @logger.create_message(StandardError.new('a')))
      assert_kind_of(Hash, @logger.create_message(Error.new('a')))
      assert_kind_of(Array, @logger.create_message([1, 2, 3]))
      assert_kind_of(Hash, @logger.create_message(a: 'a', b: 'b'))
      assert_kind_of(String, @logger.create_message('aaaaa'))
      assert_equal('string', @logger.create_message('string'))
      assert_equal({message: 'message'}, @logger.create_message(message: 'message', password: 'hoge'))
      # 行番号をベタ書きすると、このファイルを編集するたびに腐る（実際ずっと
      # 落ちていた）。raise の位置から動的に取る。
      expected_line = __LINE__ + 1
      raise AuthError, 'unauthorized'
    rescue AuthError => e
      assert_equal({
        error: {
          message: 'unauthorized',
          file: 'test/logger_test.rb',
          line: expected_line,
        },
        class: 'Ginseng::LoggerTest',
      }, @logger.create_message(error: e, class: self.class.to_s))
    end

    # ログに渡しただけで呼び出し元の Hash が壊れてはいけない (#478)。
    def test_create_message_does_not_mutate_source
      params = {message: 'message', password: 'hoge', nested: {token: 'x', keep: 'y'}}
      @logger.create_message(params)

      assert_equal('hoge', params[:password])
      assert_equal('x', params.dig(:nested, :token))
    end

    # 文字列キーでもマスクが効くこと。旧実装は symbolize_keys した複製を回しつつ
    # 元の arg を delete していたため、文字列キーでは素の値が出ていた (#478)。
    def test_create_message_masks_string_keys
      assert_equal(
        {message: 'message'},
        @logger.create_message('message' => 'message', 'password' => 'hoge'),
      )
    end

    def test_create_message_masks_nested_values
      assert_equal(
        {a: {b: {keep: 'y'}}},
        @logger.create_message(a: {b: {secret: 'x', keep: 'y'}}),
      )
    end

    # URL の**クエリに埋まった**資格情報が落ちること
    # (pooza/mulukhiya-toot-proxy#4511)。キー名は `url` なので mask_fields では
    # 素通りする。mulukhiya の listener がフルスコープのボットトークンを平文で
    # syslog へ書き続けていた実例がある。
    def test_create_message_masks_url_credentials
      message = @logger.create_message(
        url: 'wss://example.com/api/v1/streaming?access_token=SECRET&stream=user',
      )

      assert_not_include(message[:url], 'SECRET')
      assert_include(message[:url], '[FILTERED]')
      assert_include(message[:url], 'stream=user', '無関係なパラメータは残す')
      assert_include(message[:url], 'wss://example.com/api/v1/streaming', 'ホストとパスは残す')
    end

    # Misskey のトークンパラメータ `i` も落ちること。汎用名なので URL のクエリに
    # 限って判定している。
    def test_create_message_masks_misskey_token_param
      message = @logger.create_message(url: 'https://example.com/streaming?i=SECRET')

      assert_not_include(message[:url], 'SECRET')

      # Hash のキーとしての :i は URL ではないので落とさない（落とすと無関係な
      # 値まで消える）。
      assert_equal({i: 'plain value'}, @logger.create_message(i: 'plain value'))
    end

    # 資格情報を含まない URL・URL でない文字列は素通しすること。
    def test_create_message_keeps_harmless_strings
      url = 'https://example.com/path?page=2&sort=desc'

      assert_equal(url, @logger.create_message(url:)[:url])
      assert_equal('not a url? really', @logger.create_message(message: 'not a url? really')[:message])
      assert_equal('/api/v1/statuses?token=x', @logger.create_message(message: '/api/v1/statuses?token=x')[:message], 'スキームが無ければ URL 扱いしない')
    end

    # 壊れた URL でも落ちないこと（ログ出力で例外を上げるのが最悪）。
    def test_create_message_survives_malformed_url
      assert_nothing_raised do
        @logger.create_message(url: 'http://[bad?token=x')
      end
    end

    # 配列やネストの中の URL にも効くこと。
    def test_create_message_masks_url_in_nested_values
      message = @logger.create_message(a: ['https://example.com/?token=SECRET'])

      assert_not_include(message.dig(:a, 0), 'SECRET')
    end

    # ⚠ **info / error だけを見ていると穴に気づけない** (#499)。severity を
    # 変えただけで create_message を素通りし、JSON 化もマスキングもされない
    # 状態に戻る。実際に mulukhiya が warn で URL を出していた。
    data('debug', :debug)
    data('warn', :warn)
    data('fatal', :fatal)
    data('info', :info)
    def test_severity_goes_through_create_message(severity)
      captured = capture_syslog {@logger.send(severity, url: 'https://example.com/?token=SECRET', password: 'hoge')}
      # JSON であること（Hash#to_s へ倒れていない）。
      body = JSON.parse(captured.first)

      assert_equal(1, captured.size)
      assert_not_include(body['url'], 'SECRET')
      assert_not_include(body.keys, 'password')
    end

    private

    # Syslog::Logger の各 severity は add へ集約されるので、そこで捕まえる。
    def capture_syslog
      captured = []
      @logger.define_singleton_method(:add) do |_severity, message = nil, _progname = nil|
        captured.push(message)
        true
      end
      yield
      return captured
    end
  end
end
