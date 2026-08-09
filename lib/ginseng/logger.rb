# frozen_string_literal: true

module Ginseng
  if Environment.win?
    class Logger
      def info(message)
      end

      def error(message)
      end

      def debug(message)
      end

      def warn(message)
      end

      def fatal(message)
      end
    end
  else
    require 'syslog/logger'
    class Logger < Syslog::Logger
      include Package

      FILTERED = '[FILTERED]'
      # query_values= が値に使う encode 規則。encode_component の既定の
      # charclass では角括弧が残ってしまい、実際の出力と一致しない。
      FILTERED_ENCODED = Addressable::URI.encode_component(
        FILTERED,
        Addressable::URI::CharacterClasses::UNRESERVED,
      ).freeze

      # URL のクエリに現れたら落とす資格情報パラメータの既定値。
      # config の `/logger/mask_query_params` で上書きできる。
      MASK_QUERY_PARAMS = [
        'access_token',
        'api_key',
        'apikey',
        'client_secret',
        'code',
        'i',
        'key',
        'password',
        'refresh_token',
        'secret',
        'token',
      ].freeze

      URL_PATTERN = %r{\A[a-z][a-z0-9+.-]*://}i

      def initialize(name = nil)
        @config = config_class.instance
        name ||= package_class.name
        super
      end

      def info(message)
        super(create_message(message).to_json)
      end

      def error(message)
        super(create_message(message).to_json)
        return unless message.is_a?(StandardError)
        message.backtrace.each do |entry|
          super("  #{entry}")
        end
      end

      # ⚠ **info / error 以外の severity も create_message を通すこと** (#499)。
      # ここを空けておくと、`warn` を使った瞬間に出力が Hash#to_s へ戻り、
      # mask / mask_url（#478、pooza/mulukhiya-toot-proxy#4511）が丸ごと効かなく
      # なる。severity は syslog の重要度として正当な使い分けなので、呼び出し側を
      # info へ書き換えて回るのではなくここで塞ぐ。
      # error はバックトレース展開があるので上で個別に定義している。
      #
      # ⚠ **ブロック形式 (`logger.warn {expensive}`) を殺さないこと。**Syslog::Logger
      # の severity メソッドは message 省略 + ブロックを受けるので、必須引数にすると
      # 既存の呼び出しが ArgumentError になる。severity が無効なときはブロックを
      # 評価しない（遅延の意味が失われる）。
      [:debug, :warn, :fatal].each do |severity|
        define_method(severity) do |message = nil, &block|
          return true unless send(:"#{severity}?")
          message = block.call if message.nil? && block
          super(create_message(message).to_json)
        end
      end

      def create_message(src)
        case src
        in {error: error}
          file, line = error.backtrace.first.split(':')
          return mask(src.merge(error: {
            message: error.message,
            file: file.sub("#{Environment.dir}/", ''),
            line: line.to_i,
          }))
        in Hash
          return mask(src)
        in StandardError
          return src.to_h
        end
      rescue
        return src
      end

      private

      # ログ出力用にマスクした複製を返す。
      #
      # ⚠ 引数は変更しないこと。以前は arg.delete / arg[k]= で入力そのものを
      # 書き換えており、ログに渡しただけで呼び出し元の Hash から mask_fields の
      # キーが消えていた（mulukhiya で Sinatra の params が壊れた実例あり）。
      # 加えて、文字列キーの Hash では symbolize_keys した複製を回しながら元の
      # arg を delete するためマスクが効かず、シンボルキーが二重に生えたうえで
      # 素の値がログに出ていた (#478)。
      def mask(arg)
        case arg
        in Hash
          entries = arg.symbolize_keys.reject {|k, v| v.to_s.empty? || mask_field?(k)}
          return entries.transform_values {|v| mask(v)}
        in Array
          return arg.reject {|v| v.to_s.empty?}.map {|v| mask(v)}
        in String
          return mask_url(arg)
        else
          return arg
        end
      end

      def mask_field?(key)
        return @config['/logger/mask_fields'].include?(key.to_s)
      end

      # URL のクエリに埋まった資格情報を落とす
      # (pooza/mulukhiya-toot-proxy#4511)。
      #
      # mask_field? はキー名でしか判定できないため、`url: "...?access_token=xxx"`
      # のように**値の文字列の中に埋まった**トークンは素通りしていた。実際に
      # mulukhiya の listener がフルスコープのボットトークンを平文で syslog へ
      # 書き続けていた。HTTP#log も毎リクエスト url: を出すので、局所対処では
      # なく Logger 側に置く。
      #
      # ⚠ 判定は URL のクエリに限ること。`i` は Misskey のトークンパラメータだが
      # 汎用名すぎるので、Hash のキーや素の文字列にまで広げると無関係な値まで
      # 落としてしまう。
      def mask_url(value)
        return value unless value.include?('?')
        return value unless value.match?(URL_PATTERN)
        uri = Addressable::URI.parse(value)
        query = uri.query_values(Array)
        return value if query.blank?
        return value unless query.any? {|k, _| mask_query_param?(k)}
        uri.query_values = query.map {|k, v| [k, mask_query_param?(k) ? FILTERED : v]}
        # query_values= は値を percent-encode するので、目印の角括弧が
        # `%5BFILTERED%5D` になってログが読みにくい。自分で入れた目印だけ戻す。
        return uri.to_s.gsub(FILTERED_ENCODED, FILTERED)
      rescue Addressable::URI::InvalidURIError
        return value
      end

      def mask_query_param?(key)
        return mask_query_params.include?(key.to_s.downcase)
      end

      # 設定が無い場合は既定のリストへ倒す。**マスクしない方向へは倒さない**
      # （config の不備で資格情報が平文に戻るほうが事故が大きい）。
      def mask_query_params
        @mask_query_params ||= begin
          configured = begin
            @config['/logger/mask_query_params']
          rescue ConfigError
            nil
          end
          (configured || MASK_QUERY_PARAMS).to_set {|v| v.to_s.downcase}
        end
      end
    end
  end
end
