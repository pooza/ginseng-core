# frozen_string_literal: true

require 'httparty'

module Ginseng
  # 検証で通した IP アドレスへ接続する HTTParty アダプタ
  # (pooza/mulukhiya-toot-proxy#4524)。
  #
  # ⚠ **名前で検証して名前で接続すると DNS リバインディングで抜けられる。**
  # allowlist の判定時は公開 IP を、接続時は 127.0.0.1 を返す権威 DNS を立てれば、
  # 検証を素通りして内部サービスへ到達できる（TOCTOU）。TTL 0 の応答を返せば
  # OS・resolver のキャッシュもほぼ効かない。判定と接続で名前を二度引く限り、
  # ホップごとの検証（#4410）やプリフライトの検証（#4523）を足しても塞がらない。
  #
  # `Net::HTTP#ipaddr=` は **接続先だけ**を IP に差し替える。`Host:` ヘッダと
  # TLS の SNI・証明書検証はホスト名のまま行われるので HTTPS の検証は壊れない。
  class PinnedAddressAdapter < HTTParty::ConnectionAdapter
    # 接続先を address に固定した options を返す。address が nil なら素通し
    # （真偽値を返す従来の validator は pinning しない）。
    def self.pin(options, address)
      return options unless address
      return options.merge(
        connection_adapter: self,
        connection_adapter_options:
          (options[:connection_adapter_options] || {}).merge(pinned_address: address),
      )
    end

    def connection
      http = super
      address = options.dig(:connection_adapter_options, :pinned_address)
      http.ipaddr = address if address.present?
      return http
    end
  end
end
