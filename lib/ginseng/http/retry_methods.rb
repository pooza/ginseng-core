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
      # URL をメッセージに載せる例外 (#703)。⚠ `::URI` と書く（素の `URI` は `Ginseng::URI`）。
      URI_ERRORS = [HTTParty::UnsupportedURIScheme, ::URI::InvalidURIError, Addressable::URI::InvalidURIError].freeze

      private

      def repeat(method, uri, start, quiet: nil)
        cnt ||= 0
        yield
      rescue Net::ReadTimeout => e
        log_retry_error(e, method, uri, start)
        raise_gateway_error(e, e)
      rescue => e
        original = e
        e = redact_uri_error(e)
        cnt += 1
        seconds = retry_after(e)
        gave_up = give_up_reason(e, cnt, seconds)
        # ⚠ **再送するかを決めてから出す (#662)。** 行は従来どおり落ちた試行 1 回につき
        # 1 本（利用側が `count` を持つ行を「落ちた試行」として数えている）。
        unless quiet_failure?(e, gave_up, quiet)
          log_retry_error(e, method, uri, start, count: cnt, retry_after: seconds, gave_up:)
        end
        raise_gateway_error(e, original) if gave_up
        sleep(seconds || retry_seconds)
        retry
      end

      # 呼び出し側が「想定内」と言った状態コードで落ちた試行か (#672)。
      #
      # `options[:quiet_statuses]` に状態コードの配列を渡すと、その状態で落ちた試行は
      # エラー行を出さない。⚠ **例外はこれまでどおり投げる** — 止めるのは行だけ。
      # （HEAD に応じない相手へのプリフライトのように、**呼び出し側が握りつぶすと
      # 決めている失敗**の行は、上流で出すと呼び出し側からは止められない。）
      #
      # ⚠⚠ **再送する状態（429 / 5xx など）は、指定されても黙らせない。**
      # 🔴 あの行は「なぜ待った・諦めたか」を運ぶ（#662）うえ、利用側が `count` を持つ行を
      # 「落ちた試行」として数えている。**黙らせてよいのは、1 回で終わる恒久的な答えだけ** —
      # `retryable?` を上書きして再送に倒した状態（tomato-shrieker の 404）も同じ扱いになる。
      # ⚠ **上流が実際に返した応答があるときだけ。** `PinningError` / `TooLargeError` も
      # `:not_retryable` で、応答を持たない例外の `source_status` は 502 へ倒れるので、
      # 🔴 **`response` を見ないと「502 は想定内」の指定で設定ミスの行まで消える**。
      #
      # ⚠ **消えるのは error の行だけ。** 応答があった試行の info 行（URL と状態コード）は
      # 残る。⚠⚠ **401 / 403 を挙げると、資格情報の失効も error からは消える** —
      # error だけを監視へ流している運用では、挙げる側がそれを承知していること。
      # ⚠ **リダイレクトの先（別オリジン）の答えにも効く。** `host_validator` を渡さない
      # 経路は HTTParty が追い切った最後の答えを見るので、🔴 **渡したときだけ初段に限ると、
      # validator の有無でログの形が変わる**。
      #
      # ⚠⚠ **`Range` は配列にしない（リリース前レビュー）。** 🔴 `Array(400..)` は
      # `RangeError` を上げ、ここは `repeat` の `rescue` の中なので、**本来の
      # `GatewayError` を置き換えてしまう**（しかも失敗した瞬間に初めて出る）。
      def quiet_failure?(error, gave_up, quiet)
        return false unless quiet && gave_up == :not_retryable
        return false unless error.is_a?(GatewayError) && error.response
        return quiet.cover?(error.source_status) if quiet.is_a?(Range)
        return Array(quiet).include?(error.source_status)
      end

      # 諦める理由。再送するなら nil。
      #
      # ⚠⚠ **相手が長い待ちを指定したら、待たずに諦めて呼び出し側へ返す (#525)。**
      # プロセスを何分も止めるのは呼び出し側の期待を超える。**「次の機会に回す」
      # 判断は呼ぶ側のもの**なので、こちらは例外で返す。
      # 🔴 **上限は `Retry-After` 由来の値にだけ掛ける (#549)。** 固定値にも
      # 掛けると、`/http/retry/seconds` を 60 より大きくしているアプリで
      # **ヘッダの無い 503 や接続断まで 1 回で諦める**ようになる。
      def give_up_reason(error, count, seconds)
        return :not_retryable unless retryable?(error)
        return :retry_limit unless count < retry_limit
        return :retry_after_too_long if seconds && seconds > max_retry_seconds
        return nil
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

      # ⚠⚠ **429 は、なぜ待った・諦めたかを行に残す (#662)。** 読めた待ちの秒数
      # （`retry_after`）と、あれば `X-RateLimit-Reset` の値（窓の明ける時刻）を添える。
      # ⚠ 諦めた回は `gave_up` に理由を添える。🔴 **待ちが長すぎて諦めた回
      # （`retry_after_too_long`）と `retry_limit` を使い切った回は、`count` だけでは
      # 区別できない**（前者も `count: 1` の 1 本で終わる）。
      #
      # ⚠ `count` は nil でもキーごと出す（従来の形。`Net::ReadTimeout` の行は持たない）。
      # ⚠⚠ **URI の例外は、メッセージに URL を丸ごと載せる (#703)。** HTTParty の
      # `UnsupportedURIScheme` は `'<URL>' Must be HTTP, HTTPS or Generic`、`URI::InvalidURIError` は
      # `bad URI (is not URI?): "<URL>"`。🔴 ログのマスクは `scheme://` の形で**読める** URL しか
      # 伏せないので、`myapp:/callback?code=SECRET` のような `Location` も、読めない URL も
      # **ログの行と包み直した `GatewayError` の両方に平文で出ていた**。
      #
      # ⚠ **スキームとホストだけ残す。** 要求先の URL はログの `url:` に（伏せた形で）残るので、
      # 診断に要るのは「どんな形の URL だったか」まで。⚠ 同じクラスで作り直す（`retryable?` と
      # 利用側の `rescue` がクラスで見ている）。
      def redact_uri_error(error)
        return error unless URI_ERRORS.any? {|klass| error.is_a?(klass)}
        redacted = error.class.new(redact_uri_message(error.message))
        redacted.set_backtrace(error.backtrace)
        return redacted
      rescue ArgumentError
        # ⚠ 引数の違う独自の例外クラスでも、URL を載せたまま返さない。
        redacted = GatewayError.new("#{error.class}: #{Masking::FILTERED}")
        redacted.set_backtrace(error.backtrace)
        return redacted
      end

      # ⚠ 引用符の中を丸ごと縮める。**最後の同じ引用符まで**取る（URL の中に引用符が
      # あっても途中で切らない）。引用符が無ければ、メッセージごと伏せる。
      def redact_uri_message(message)
        message = message.to_s.scrub('?')
        return Masking::FILTERED unless match = message.match(/(['"])(.*)\1/m)
        quote = match[1]
        return "#{match.pre_match}#{quote}#{uri_origin(match[2])}#{quote}#{match.post_match}"
      end

      # `scheme:` と、読めるホストだけを残す。⚠ userinfo とポート以外の後ろは全部落とす。
      def uri_origin(src)
        scheme = src[/\A[a-z][a-z0-9+.-]*:/i]
        return Masking::FILTERED unless scheme
        host = src.delete_prefix(scheme)[%r{\A//([^/?#\\]*)}, 1]
        # ⚠ `@` の前（userinfo）は落とす。ホストの形をしていなければホストも出さない
        # （`//user:pa/ss@h` のように、区切りが崩れた形でパスワードの断片を出さないため）。
        host = host&.split('@')&.last
        host = nil unless host&.match?(/\A(?:[a-z0-9.-]+|\[[0-9a-f:.]+\])(?::\d+)?\z/i)
        origin = host ? "#{scheme}//#{host}" : scheme
        return origin == src ? origin : "#{origin}#{Masking::FILTERED}"
      end

      # 包み直して投げる。⚠⚠ **`cause` には伏せた形のものだけを付ける (#703 Codex P1)。**
      # 🔴 `rescue` の中の `raise` は、**捕まえた元の例外を自動で `cause` に付ける**ので、
      # メッセージを伏せても `cause` から平文の URL が読めた（Sentry は `cause` を辿る）。
      # - URI の例外: 縮めた複製を `cause` にする（クラスとバックトレースは同じ）
      # - その他: **連鎖のどこかに伏せるものがあれば** `cause` を付けない（元の例外は作り直せない）。
      #   🔴 外側のメッセージだけ見ていると、無害な例外の `cause` に入れ子になった URI の例外が
      #   そのまま残った（Codex P1・2 巡目）。何も無ければ従来どおり元の例外
      #
      # ⚠ **GatewayError はそのまま投げ直す**（`response` と派生クラスを保つため）。⚠⚠ 既に付いた
      # `cause` は `raise e, cause: nil` でも `dup` でも外せない（実測）。この gem の GatewayError は
      # `rescue` の中では投げていないので、`cause` は `nil` になっている。**`rescue` の中で
      # 投げる箇所を足すときは、ここが効かないことに注意。**
      def raise_gateway_error(error, original)
        wrapped = gateway_error(error)
        raise wrapped if wrapped.equal?(original)
        raise wrapped, cause: error unless error.equal?(original)
        raise wrapped, cause: (safe_cause?(original) ? original : nil)
      end

      # 例外の連鎖を残してよいか。⚠ 循環に備えて、同じ例外は 2 度見ない。
      def safe_cause?(error)
        seen = Set.new
        while error && seen.add?(error.object_id)
          return false if URI_ERRORS.any? {|klass| error.is_a?(klass)}
          return false unless masked_message?(error.message.to_s)
          error = error.cause
        end
        return true
      end

      # ⚠ マスクを掛けても変わらない（＝伏せるものが無い）メッセージか。
      def masked_message?(message)
        return true unless @logger.respond_to?(:mask_urls_in)
        return @logger.mask_urls_in(message) == message
      end

      def log_retry_error(error, method, uri, start, **detail)
        entry = {error:, method: method.upcase.to_sym, url: uri.to_s, start:, count: detail[:count]}
        entry.merge!(detail.except(:count).compact)
        reset = ratelimit_reset_header(error)
        entry[:ratelimit_reset] = reset if reset
        entry[:max_seconds] = max_retry_seconds if detail[:gave_up] == :retry_after_too_long
        @logger.error(entry)
      end

      # 429 の応答の `X-RateLimit-Reset`（生の値）。無ければ nil。
      def ratelimit_reset_header(error)
        return nil unless error.is_a?(GatewayError) && error.source_status == 429
        return response_header(error.response, 'x-ratelimit-reset').to_s.strip.presence
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
      #
      # ⚠⚠ **`Retry-After` が無ければ `X-RateLimit-Reset`（ISO 8601）を読む**
      # (pooza/makoto2#425)。🔴 **Mastodon は 429 に `Retry-After` を付けない**
      # （`rack_attack.rb` の `throttled_responder` も `Api::RateLimitHeaders` も
      # `X-RateLimit-Reset` だけ）ので、**Mastodon 相手では #525 の「従う」が効いて
      # いなかった。**⚠ **`Retry-After` があればそちらが勝つ**（RFC のヘッダが正本）。
      def retry_after(error)
        return nil unless error.is_a?(GatewayError)
        return nil unless error.source_status == 429
        value = response_header(error.response, 'retry-after').to_s.strip
        return ratelimit_reset(error.response) if value.empty?
        return [value.to_i, 0].max if value.match?(/\A[[:digit:]]+\z/)
        return [(Time.httpdate(value) - Time.now).ceil, 0].max
      rescue ArgumentError
        # HTTP-date として読めない値。⚠ **待ち方が分からないだけなので、
        # 従来どおりの固定値へ倒す**（ここで raise すると再送そのものが消える）。
        return nil
      end

      # `X-RateLimit-Reset`（ISO 8601 の時刻）を、いまからの秒数として読む。
      # ⚠ **無い・読めなければ nil**（固定値へ倒す → `retry_after`）。
      def ratelimit_reset(response)
        value = response_header(response, 'x-ratelimit-reset').to_s.strip
        return nil if value.empty?
        return [(Time.iso8601(value) - Time.now).ceil, 0].max
      rescue ArgumentError
        return nil
      end

      # 応答からヘッダを取り出す。
      #
      # ⚠⚠ **応答の型が 2 つある (#549)。** `HTTParty::Response` は `headers` を
      # 持つが、`#mkcol` が添える `Net::HTTPResponse` は持たず `response[name]`
      # で読む。⚠ **`HTTParty::Response#[]` は body（パース結果）を引く**ので、
      # `headers` を先に見ること。
      def response_header(response, name)
        return response.headers[name] if response.respond_to?(:headers)
        return response[name] if response.respond_to?(:[])
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
