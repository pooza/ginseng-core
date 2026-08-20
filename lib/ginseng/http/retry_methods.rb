# frozen_string_literal: true

module Ginseng
  class HTTP
    # 再送の方針。⚠ **どこまで待つか・何を再送するか**をここに集める (#525)。
    #
    # ⚠ **HTTP 本体から切り出してあるが、置き場所に強い理由は無い。**
    # ByteLimitMethods / HostValidationMethods と同じく Metrics/ClassLength に
    # 収めるための分割で、**中身は変えていない**。
    #
    # ⚠ `retryable?` を override して方針を変えるアプリがある
    # (pooza/tomato-shrieker の retry_not_found)。**module に移しても
    # サブクラスの定義が勝ち、`super` も従来どおり効く。**
    module RetryMethods
      private

      def repeat(method, uri, start)
        cnt ||= 0
        yield
      rescue Net::ReadTimeout => e
        log_retry_error(e, method, uri, start)
        raise gateway_error(e)
      rescue => e
        cnt += 1
        log_retry_error(e, method, uri, start, count: cnt)
        raise gateway_error(e) unless retryable?(e) && cnt < retry_limit
        seconds = retry_after(e)
        # ⚠⚠ **相手が長い待ちを指定したら、待たずに諦めて呼び出し側へ返す (#525)。**
        # プロセスを何分も止めるのは呼び出し側の期待を超える。**「次の機会に回す」
        # 判断は呼ぶ側のもの**なので、こちらは例外で返す。
        # 🔴 **上限は `Retry-After` 由来の値にだけ掛ける (#549)。** 固定値にも
        # 掛けると、`/http/retry/seconds` を 60 より大きくしているアプリで
        # **ヘッダの無い 503 や接続断まで 1 回で諦める**ようになる。
        raise gateway_error(e) if seconds && seconds > max_retry_seconds
        sleep(seconds || retry_seconds)
        retry
      end

      # 再送して結果が変わりうるか。
      #
      # ⚠ **恒久的な失敗を再送しない。** 401 / 403 / 422 を投げ直しても結果は同じで、
      # 待ち時間と相手への負荷とエラーログだけが retry_limit 倍になる。
      # 408（タイムアウト）/ 425（Too Early）/ 429（レート制限）は時間をおけば
      # 通るので再送する。ステータスを取り出せない失敗（接続断など）も再送する。
      #
      # 方針を変えたいアプリはこのメソッドを override する。
      def retryable?(error)
        # ⚠ pinning できない = 設定の問題なので、試行の間に変わらない。既定では
        # source_status が 502 になり「上流の一時障害」として 5 回叩き直して
        # しまうため、ここで明示的に落とす。
        # ⚠ 上限超過 (TooLargeError) も同じ。相手が同じものを返す限り同じ場所で
        # 超えるだけで、再送のたびに上限ぶんの転送とメモリを食う (#526)。
        return false if error.is_a?(PinningError) || error.is_a?(TooLargeError)
        return true unless error.is_a?(GatewayError)
        status = error.source_status
        return true if RETRYABLE_STATUSES.include?(status)
        return status >= 500
      end

      def log_retry_error(error, method, uri, start, count: nil)
        @logger.error(
          error:,
          method: method.upcase.to_sym,
          url: uri.to_s,
          start:,
          count:,
        )
      end

      def retry_seconds
        return @config['/http/retry/seconds']
      end

      # `Retry-After` を秒数として読む。⚠ **読めなければ nil**（呼び出し側は
      # 固定値へ倒す）。
      #
      # ⚠⚠ **429 は「いつ再開してよいか」を相手が明示している唯一のステータス**
      # なので、そこだけ従う (#525、pooza/makoto2#100)。⚠ **固定値で叩き直すと、
      # 規制されている最中に retry_limit 回連打して規制を長引かせる方向に効く。**
      # 408 / 425 は「相手が意図的に断っている」わけではないので固定値のまま。
      #
      # ⚠ **秒数と HTTP-date の両方の形がある** (RFC 9110)。⚠ 過去の日付や負の値は
      # 0 に倒す（`sleep` に負数を渡すと ArgumentError になる）。
      def retry_after(error)
        return nil unless error.is_a?(GatewayError)
        return nil unless error.source_status == 429
        value = retry_after_header(error.response).to_s.strip
        return nil if value.empty?
        return [value.to_i, 0].max if value.match?(/\A[[:digit:]]+\z/)
        return [(Time.httpdate(value) - Time.now).ceil, 0].max
      rescue ArgumentError
        # HTTP-date として読めない値。⚠ **待ち方が分からないだけなので、
        # 従来どおりの固定値へ倒す**（ここで raise すると再送そのものが消える）。
        return nil
      end

      # 応答から `Retry-After` を取り出す。
      #
      # ⚠⚠ **応答の型が 2 つある (#549)。** `HTTParty::Response` は `headers` を
      # 持つが、`#mkcol` が添える `Net::HTTPResponse` は持たず `response[name]`
      # で読む。⚠ **`HTTParty::Response#[]` は body（パース結果）を引く**ので、
      # `headers` を先に見ること。
      def retry_after_header(response)
        return response.headers['retry-after'] if response.respond_to?(:headers)
        return response['retry-after'] if response.respond_to?(:[])
        return nil
      end

      # `Retry-After` として受け入れる上限。⚠ **設定が無ければ既定へ倒す**
      # （利用側の config には無いキーなので、ConfigError を通さない）。
      def max_retry_seconds
        @max_retry_seconds ||= begin
          @config['/http/retry/max_seconds']
        rescue ConfigError
          MAX_RETRY_SECONDS
        end
      end
    end
  end
end
