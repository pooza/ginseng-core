# frozen_string_literal: true

module Ginseng
  class HTTP
    # リダイレクトを自前で追う経路。host_validator を渡されたときは、
    # **ホップごとに**ホストを検証して pinning する (mulukhiya-toot-proxy#4410 /
    # #4524)。
    #
    # ⚠⚠ **6.0.0 から、validator を渡さない要求もここを通る (#655)。** 以前は HTTParty に
    # 追わせていて、1 段目の `Set-Cookie` が別ホストの 2 段目へ送られていた。
    # ⚠ module の名前は経緯のまま。validator は nil でよい。
    #
    # ⚠ **HTTP 本体から切り出してあるが、置き場所に強い理由は無い。**
    # ByteLimitMethods と同じく Metrics/ClassLength に収めるための分割。
    # ⚠ #653 で資格情報の一覧を `HTTP` へ移し、`follow_redirects: false` を
    # 尊重するようにした（切り出した当時の中身からは変わっている）。
    module HostValidationMethods
      # ⚠⚠ **メソッドと body を保つリダイレクト (#569)。** それ以外は GET に
      # 化ける（303 は仕様、301 / 302 は歴史的経緯）。⚠ body 付きメソッドに
      # ついては **HTTParty 自身の `handle_redirection` と同じ規則**にしてある
      # — 自前で追う経路だけ挙動が違うと、validator を足したせいで結果が
      # 変わることになる。
      KEEP_METHOD_STATUSES = [307, 308].freeze

      # ⚠⚠ **HEAD は GET に化けさせない。** ⚠ HTTParty も HEAD のまま追う（実測で 2 段目は
      # HEAD だった。2026-11-07・httparty 0.24.3）。
      # 🔴 **`#head` はサイズのプリフライトに使われる** (mulukhiya-toot-proxy#4523)
      # ので、リダイレクトの先で GET に化けると**本文を丸ごと取ってしまい、
      # プリフライトの意味が消える**（max_bytes も効かせられない）。
      # ⚠ POST を GET へ化けさせる理由は「撃ち直して安全とは限らない」ことなので、
      # 安全かつ本文を持たない HEAD には当てはまらない（curl -I -L も HEAD のまま）。
      SAFE_METHODS = [:get, :head].freeze

      # 追ってよい行き先のスキーム。→ `redirect_uri`
      REDIRECT_SCHEMES = ['http', 'https'].freeze

      private

      def request_validating_hops(method, uri, options, validator, max_bytes = nil)
        # 🔴🔴 **呼び出し側の「追わない」を、merge で消す前に読む (#653 Codex P1)。**
        # ⚠⚠ この経路は `follow_redirects: false` を **HTTParty へ**渡したうえで
        # **自前でホップを追う**ので、`RedirectGuard` が同じキーを立てても
        # **追従は止まらなかった**。🔴 307 / 308 は `redirect_options` が body を
        # 持ち越すため、**`client_secret` のような本文の資格情報が、validator の
        # 通る別ホストへそのまま渡っていた**（オリジンが変われば落とすのは
        # ヘッダと資格情報オプションだけ）。
        # ⚠⚠ **`nil` は「追う」ではない。** HTTParty は `follow_redirects` を素の
        # 真偽で見るので `nil` なら追わない。🔴 ここだけ `!= false` で見ていると
        # **`follow_redirects: config['...']` のようにキーが在って値が `nil` の形で、
        # この経路だけ追ってしまう**（`RedirectGuard` は `key?` で判定するため、
        # 呼び出し側の明示として素通りする）。
        follow = !options.key?(:follow_redirects) || options[:follow_redirects].present?
        options = options.merge(follow_redirects: false)
        limit = options.delete(:max_redirects) || MAX_REDIRECTS
        origin = origin_of(uri)
        (limit + 1).times do
          response = request_hop(method, uri, options, validator, max_bytes)
          location = redirect_location(response)
          # ⚠ **追わないと言われていたら 3xx をそのまま返す。** 5.x まで validator を渡さない
          # 経路（HTTParty に任せていた側）と同じ形 — 3xx を落とすかどうかは
          # 呼び出し側（`RedirectGuard#guard_response`）が決める。
          return response unless follow && location
          uri = redirect_uri(method, uri, location)
          # ⚠ **メソッドはホップごとに変わりうる (#569)。** GET / HEAD しか
          # 通っていなかった頃は `method` が不変だったが、body 付きメソッドを
          # 通すようになったので追従させる。
          # ⚠⚠ **「メソッドを保つ」と「body を保つ」は別の条件。** 一緒にすると、
          # GET に body を渡した呼び出しで**初段の body が撃ち直される**。
          # 🔴🔴 **GET / HEAD の本文は 307 / 308 でも持ち越さない（6.0.0 のリリース前レビュー）。**
          # ⚠⚠ 5.x の既定の経路は HTTParty が追っていて、GET の本文は必ず捨てていた（`clear_body`）。
          # ここだけ持ち越していたので、6.0.0 で既定の経路もここを通すと**本文付きの GET が 307 で
          # 別ホストへ本文ごと撃ち直された**（実測: `client_secret=SECRET` が 2 段目に届いた）。
          keep_method = KEEP_METHOD_STATUSES.include?(response.code)
          keep_body = keep_method && !SAFE_METHODS.include?(method)
          method = :get unless keep_method || SAFE_METHODS.include?(method)
          options = redirect_options(options, origin, uri, keep_body:)
        end
        # ⚠ **諦めた行を 1 本残す（6.0.0 のリリース前レビュー）。** ここは `repeat` の外なので、
        # 残さないと info 行が並ぶだけで error 行が 1 本も出ない（5.x は HTTParty の例外が `repeat` で出ていた）。
        error = GatewayError.new("Too many redirects (#{limit})")
        log_retry_error(error, method, uri, Time.now, gave_up: :too_many_redirects)
        raise error
      end

      # 次のホップの URI。
      #
      # 🔴🔴 **読めない `Location` の例外を、素のまま外へ出さない（#743 Codex P2 / #695）。**
      # ⚠⚠ `URI::InvalidURIError` は `bad URI (is not URI?): "<Location 全体>"` を載せ、ここは
      # `repeat` の外なので `redact_uri_error` も `GatewayError` への包み直しも通らない。実測で
      # `Location: https://[::1/cb?code=SECRET` の `SECRET` が平文で出た。🔴 5.x の既定の経路は
      # HTTParty が `execute` の中で追っていたので伏せてあり、6.0.0 で既定の経路もここを
      # 通るようになって**回帰した**（validator の経路は以前から同じ形だった）。
      # ⚠ 包むのは `repeat` と同じ形（伏せた複製を `cause` に付けた `GatewayError`）。行も 1 本残す。
      #
      # 🔴🔴 **http / https 以外の行き先も、ここで止める（6.0.0 のリリース前レビュー）。**
      # ⚠⚠ `myapp:/cb?code=SECRET` は `URI.join` を通るので、次のホップの `url:` としてログへ渡り、
      # **ログのマスクは `scheme://` の形しか伏せないので平文で出た**（#703 で塞いだ形が別の欄から）。
      # しかも送れない行き先なのに、`UnsupportedURIScheme` を `retry_limit` 回撃ち直していた。
      # ⚠ 行には直前のホップの URL を残し、行き先はスキームだけにする（`uri_origin`）。
      def redirect_uri(method, uri, location)
        target = ::URI.join(uri.to_s, location)
        return create_uri(target.to_s) if REDIRECT_SCHEMES.include?(target.scheme.to_s.downcase)
        error = GatewayError.new("Unsupported redirect to '#{uri_origin(location.to_s)}'")
        log_retry_error(error, method, uri, Time.now, gave_up: :invalid_location)
        raise error
      rescue *RetryMethods::URI_ERRORS => e
        redacted = redact_uri_error(e)
        log_retry_error(redacted, method, uri, Time.now, gave_up: :invalid_location)
        raise_gateway_error(redacted, e)
      end

      # ホップ 1 回ぶん。⚠ 検証は `repeat` の外で行う — 中に置くと、拒否した相手を
      # retry_limit 回叩き直すうえ、`GatewayError` の再送判定にも巻き込まれる。
      # ⚠ pinning は**ホップごとに付け替える**。リダイレクト先は別ホストなので、
      # 前のホップのアドレスを引き継ぐと繋ぎ先を間違える。
      def request_hop(method, uri, options, validator, max_bytes)
        # ⚠ **`quiet_statuses` は options に載せたままホップを渡り歩く (#672)。**
        # 取り出すのはここだけ（HTTParty へは渡さない）。リダイレクト先の答えにも効く。
        quiet = options[:quiet_statuses]
        # ⚠ **validator が無ければ検証も pinning もしない (#655)。** 既定の経路もここを
        # 通るようになったが、ホストの判断は持ち込まない（追い方と資格情報の落とし方だけ揃える）。
        address = validator ? validate_host!(uri, validator) : nil
        hop_options = PinnedAddressAdapter.pin(options.except(:quiet_statuses), address)
        return repeat(method, uri, start = Time.now, quiet:) do
          response = execute(method, uri, hop_options, max_bytes)
          # ⚠ **`multipart` はホップごとに変わる (#578)。** `upload_options` が
          # 立てた印は body と一緒に落ちるので、`slice` でそのまま写す。
          # ⚠ キーの順は `method:, multipart:, url:, status:`。5.x の `upload` の直行経路と同じ
          # 並び（6.0.0 で直行経路は無くなったが、行の形は変えない）。
          log(method:, **hop_options.slice(:multipart), url: uri, status: response.code, start:)
          bad_response!(response) unless response.code < 400
          next response
        end
      end

      # リダイレクト先へ持ち越す options を作る (#527)。
      #
      # ⚠⚠ **初段の query / body を撃ち直さない。** Location は撃ち直す先を
      # クエリまで含めて指しているので、初段のクエリを足すと **Location が
      # 求めてもいないパラメータが次のホップに付いて回る**。そこに秘密が
      # 入っていれば、そのまま別のホストへ渡ることになる。
      #
      # ⚠⚠ **オリジンが変わったら資格情報を落とす。** `host_validator` が
      # 「公開ホストかどうか」を見る実装だと、**リダイレクト先が公開ホスト
      # でありさえすれば通る**ので、この経路は validator では塞げない。
      #
      # ⚠ **一度落ちたら戻らない。** 比較の相手は初段のオリジンで固定だが、
      # 落とした options を持ち回るので `A → B → A` と戻ってきても復活しない
      # （fail-closed 側に倒している）。
      def redirect_options(options, origin, uri, keep_body: false)
        # ⚠ **body は 307 / 308 のときだけ持ち越す (#569)。** あれはメソッド
        # ごと保つリダイレクトなので、落とすと**空の POST を撃つ**ことになる。
        # ⚠ **`multipart` は body と一緒に落とす (#578)。** 307 / 308 以外は body を
        # 捨てて GET になるので、印だけ残すと**ログが嘘をつく**うえ、body の無い
        # 要求に `multipart: true` を渡すことになる。
        # 🔴 **`default_params` も `query` と同じく持ち越さない（6.0.0 のリリース前レビュー）。** HTTParty は
        # ホップごとにクエリへ足すので、残すと**別ホストの 2 段目に `?api_key=…` が付いた**（実測。5.x の
        # 既定の経路は HTTParty が追っていて付かなかった）。
        dropped = [:query, :default_params]
        options = keep_body ? options.except(*dropped) : options.except(*dropped, :body, :multipart)
        rewind_body!(options[:body]) if keep_body
        return options if origin == origin_of(uri)
        # ⚠ ヘッダより先に落とす。`headers` が空でも資格情報オプションは
        # 残りうるので、ここで抜けると `basic_auth` が持ち越される (#568)。
        options = options.except(*CREDENTIAL_OPTIONS)
        headers = options[:headers]
        return options if headers.blank?
        return options.merge(
          headers: headers.reject {|k, _v| HTTP.credential_header?(k)},
        )
      end

      # scheme / host / port の三つ組。⚠ **既定ポートを補って比較する。**
      # `https://example.com` と `https://example.com:443` は同じオリジンで、
      # ここで別物と見ると資格情報が無駄に落ちる。
      def origin_of(uri)
        return [uri.normalized_scheme, uri.normalized_host, uri.inferred_port]
      end

      # 撃ち直す前に body の IO を先頭へ戻す (#569)。⚠ 文字列の body には巻き
      # 戻すものが無いので何もしない。
      #
      # 🔴 **「巻き戻さないと空のファイルを送る」は、いまは成り立たない (#603)。**
      # ⚠⚠ **実測で HTTParty 自身が巻き戻していた** — `request/body.rb` の
      # `content_body` が `file.read` のあと `file.rewind` を呼び、
      # `request/streaming_multipart_body.rb` の `#rewind` も各 part を戻す
      # （`>= 0.24.0` の全域で確認）。**この行を消しても撃ち直しの本文は揃う。**
      #
      # ⚠ **それでも残すのは、上流の実装詳細に寄りかからないため。** 巻き戻しを
      # HTTParty に任せると、**向こうが止めた日に静かに空の本文を送る**ことに
      # なる。⚠⚠ **この行の効きは出力では測れない**ので、テストは
      # `redirect_options` の契約（撃ち直す前に巻き戻す）を直接押さえている。
      def rewind_body!(body)
        return unless body.is_a?(Hash)
        body.each_value {|v| v.rewind if v.respond_to?(:rewind)}
      end

      def redirect_location(response)
        # ⚠⚠ **304 はリダイレクトではない (#569)。** 3xx に入っているので
        # `between?` だけだと拾ってしまい、Location 付きの 304 を**追ってしまう**。
        # 🔴 HTTParty は `Net::HTTPNotModified` を明示的に除いているので、
        # **validator を渡したときだけ結果が変わっていた**（実測: validator あり
        # なら 200 と本文、validator 無しなら 304 と空）。
        return nil if response.code == NOT_MODIFIED
        return nil unless response.code.between?(300, 399)
        location = response.headers['location']
        return nil unless location.present?
        return location
      end

      # validator が **IP アドレス文字列**を返した場合は、その IP を接続先として
      # 返す (pooza/mulukhiya-toot-proxy#4524)。真偽値を返す従来の validator は
      # そのまま動く（検証のみで pinning はしない）。
      def validate_host!(uri, validator)
        result = validator.call(uri.host)
        raise GatewayError, "Rejected host '#{uri.host}'" unless result
        return result.is_a?(String) ? result : nil
      end
    end
  end
end
