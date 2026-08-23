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
      CREDENTIAL_OPTIONS = [:basic_auth, :digest_auth].freeze

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
            log(method:, url: uri, status: r.code, start:)
            bad_response!(r) unless r.code < 400
            r
          end
          location = redirect_location(response)
          return response unless location
          uri = create_uri(::URI.join(uri.to_s, location).to_s)
          options = redirect_options(options, origin, uri)
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
      def redirect_options(options, origin, uri)
        options = options.except(:query, :body)
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

      def redirect_location(response)
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
