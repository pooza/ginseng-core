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
        sleep(retry_seconds)
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
    end
  end
end
