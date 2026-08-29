# frozen_string_literal: true

module Ginseng
  class HTTP
    # host_validator を渡されたときの経路。リダイレクトを自前で追い、
    # **ホップごとに**ホストを検証して pinning する (mulukhiya-toot-proxy#4410 /
    # #4524)。
    #
    # ⚠ **HTTP 本体から切り出してあるが、置き場所に強い理由は無い。**
    # ByteLimitMethods と同じく Metrics/ClassLength に収めるための分割で、
    # 中身は一切変えていない。
    module HostValidationMethods
      # ⚠⚠ **オリジンをまたいで持ち出してはいけないヘッダ (#527)。**いずれも
      # 「どのオリジンに対する資格情報か」が値の側に書かれていないので、
      # 撃ち直すと**リダイレクト先に資格情報をそのまま渡すことになる**。
      CREDENTIAL_HEADERS = ['authorization', 'cookie', 'proxy-authorization'].freeze

      # ⚠⚠ **ヘッダ以外の経路で渡された資格情報 (#568)。** HTTParty は
      # `basic_auth:` / `digest_auth:` を options で受けるので、`Authorization`
      # ヘッダを見ているだけでは落としきれない。
      #
      # 🔴 **上流の抑止は、この経路では効かない。** HTTParty は自分でホップを
      # 追ったときだけ `@changed_hosts` を立てて Basic 認証を止めるが、ここは
      # `follow_redirects: false` で**ホップごとに Request を作り直す**ので、
      # 毎回 `@changed_hosts = false` の新品になる。⚠ `digest_auth` に至っては
      # 上流にその抑止すら無い。
      #
      # ⚠ **クライアント証明書 (`:pem` / `:p12`) は落とさない。** 秘密鍵は出て
      # 行かず、提示先はホップごとに `validate_host!` を通ったホストなので、
      # 落としても防げるものが無く相互 TLS が壊れるだけ。
      #
      # ⚠⚠ **`cookies:` も同じ経路 (#576)。** `Cookie` ヘッダ自体は
      # `CREDENTIAL_HEADERS` で落ちるが、HTTParty の `process_cookies` は
      # **呼び出しごとに options[:cookies] を headers['cookie'] へ移す**ので、
      # こちらが持ち回る options には `cookies:` が残ったままになり、
      # **ヘッダを見る判定に一度も掛からない**（実測でホップ 2 まで届いていた）。
      CREDENTIAL_OPTIONS = [:basic_auth, :digest_auth, :cookies].freeze

      # ⚠⚠ **メソッドと body を保つリダイレクト (#569)。** それ以外は GET に
      # 化ける（303 は仕様、301 / 302 は歴史的経緯）。⚠ body 付きメソッドに
      # ついては **HTTParty 自身の `handle_redirection` と同じ規則**にしてある
      # — 自前で追う経路だけ挙動が違うと、validator を足したせいで結果が
      # 変わることになる。
      KEEP_METHOD_STATUSES = [307, 308].freeze

      # ⚠⚠ **HEAD は GET に化けさせない。** HTTParty は化けさせるが、ここは
      # 従来から HEAD のまま追っており、テストもそれを見ている。
      # 🔴 **`#head` はサイズのプリフライトに使われる** (mulukhiya-toot-proxy#4523)
      # ので、リダイレクトの先で GET に化けると**本文を丸ごと取ってしまい、
      # プリフライトの意味が消える**（max_bytes も効かせられない）。
      # ⚠ POST を GET へ化けさせる理由は「撃ち直して安全とは限らない」ことなので、
      # 安全かつ本文を持たない HEAD には当てはまらない（curl -I -L も HEAD のまま）。
      SAFE_METHODS = [:get, :head].freeze

      # ⚠ 3xx に居るがリダイレクトではない。`redirect_location` 参照。
      NOT_MODIFIED = 304

      private

      def request_validating_hops(method, uri, options, validator, max_bytes = nil)
        options = options.merge(follow_redirects: false)
        limit = options.delete(:max_redirects) || MAX_REDIRECTS
        origin = origin_of(uri)
        (limit + 1).times do
          # 検証は repeat の外で行う。中に置くと、拒否した相手を retry_limit 回
          # 叩き直すうえ、GatewayError の再送判定にも巻き込まれる。
          # ⚠ pinning は**ホップごとに付け替える**。リダイレクト先は別ホストなので、
          # 前のホップのアドレスを引き継ぐと繋ぎ先を間違える。
          hop_options = PinnedAddressAdapter.pin(options, validate_host!(uri, validator))
          response = repeat(method, uri, start = Time.now) do
            r = execute(method, uri, hop_options, max_bytes)
            # ⚠ **`multipart` はホップごとに変わる (#578)。** `upload_options` が
            # 立てた印は body と一緒に落ちるので、`slice` でそのまま写す。
            # ⚠⚠ **validator を渡したかどうかでログの形が変わらないこと** —
            # `upload` の直行経路は `method:, multipart:, url:, status:` の順で
            # 出すので、**同じ位置に置く**（JSON のキー順が揃う）。
            log(method:, **hop_options.slice(:multipart), url: uri, status: r.code, start:)
            bad_response!(r) unless r.code < 400
            r
          end
          location = redirect_location(response)
          return response unless location
          uri = create_uri(::URI.join(uri.to_s, location).to_s)
          # ⚠ **メソッドはホップごとに変わりうる (#569)。** GET / HEAD しか
          # 通っていなかった頃は `method` が不変だったが、body 付きメソッドを
          # 通すようになったので追従させる。
          # ⚠⚠ **「メソッドを保つ」と「body を保つ」は別の条件。** 一緒にすると、
          # GET に body を渡した呼び出しで**初段の body が撃ち直される**。
          keep_body = KEEP_METHOD_STATUSES.include?(response.code)
          method = :get unless keep_body || SAFE_METHODS.include?(method)
          options = redirect_options(options, origin, uri, keep_body:)
        end
        raise GatewayError, "Too many redirects (#{limit})"
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
        options = keep_body ? options.except(:query) : options.except(:query, :body, :multipart)
        rewind_body!(options[:body]) if keep_body
        return options if origin == origin_of(uri)
        # ⚠ ヘッダより先に落とす。`headers` が空でも資格情報オプションは
        # 残りうるので、ここで抜けると `basic_auth` が持ち越される (#568)。
        options = options.except(*CREDENTIAL_OPTIONS)
        headers = options[:headers]
        return options if headers.blank?
        return options.merge(
          headers: headers.reject {|k, _v| CREDENTIAL_HEADERS.include?(k.to_s.downcase)},
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
