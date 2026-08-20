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
      private

      def request_validating_hops(method, uri, options, validator, max_bytes = nil)
        options = options.merge(follow_redirects: false)
        limit = options.delete(:max_redirects) || MAX_REDIRECTS
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
        end
        raise GatewayError, "Too many redirects (#{limit})"
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
