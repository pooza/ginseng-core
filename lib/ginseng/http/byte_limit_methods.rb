# frozen_string_literal: true

module Ginseng
  class HTTP
    # 受信バイト数の上限つきで撃つ (#526)。
    #
    # ⚠ **HTTP 本体から切り出してあるが、置き場所に強い理由は無い。**インライン化
    # したほうが読みやすければ戻してよい（Metrics/ClassLength に収めるための分割）。
    module ByteLimitMethods
      private

      # ⚠ **Content-Length を信じない。**申告が無い (chunked) 相手や過少申告する
      # 相手がいるので、事前チェックだけでは上限にならない。呼び出し側が
      # 「HEAD で Content-Length を見てから GET」と書いていても、**GET が読み切って
      # からしか気付けない** (pooza/mulukhiya-toot-proxy#4612)。
      #
      # ⚠ **stream_body は使わない。**あれを付けると HTTParty が本文を組み立て
      # なくなり `response.body` が nil になる＝**呼び出し側の契約が変わる**。
      # ブロックだけ渡せば、上限までは従来どおりの応答が返り、超えた分は読まずに
      # 中断できる（メモリは max_bytes + 断片 1 つぶんで頭打ちになる）。⚠ ただし
      # `to_s` だけは、`restore_raw_body` で戻さないと従来どおりにならない (#765)。
      def execute(method, uri, options, max_bytes = nil)
        return HTTParty.public_send(method, uri.normalize, options) unless max_bytes
        received = 0
        response = HTTParty.public_send(method, uri.normalize, options) do |fragment|
          received += fragment.bytesize
          next if received <= max_bytes
          # ⚠⚠ **メッセージに URL を入れない (#689)。** 🔴 例外のメッセージは**ロガーの外**
          # （利用側の通知・応答・別の例外への包み直し）へも運ばれ、そこでは `Masking` が
          # 掛からない。⚠ URL は `log_retry_error` が `url:` のフィールドで別に残している。
          # ⚠ **ロガーのマスクの差を塞ぐ変更ではない** — ロガーを通る分には、文中の URL も
          # フィールドの URL も同じ形に伏せられる（`Masking#mask_urls_in`。実測）。
          raise TooLargeError, "Response body exceeded #{max_bytes} bytes"
        end
        return restore_raw_body(response)
      end

      # 🔴 **ブロックを渡すと、`to_s` が本文を返さなくなる (#765)。** Net::HTTP は
      # `read_body` にブロックを渡されると `Net::HTTPResponse#body` を `Net::ReadAdapter`
      # にし、HTTParty の `Response#to_s` / `#nil?` / `#display` はそちらを読む
      # （HTTParty 0.24.3 で実測）。⚠ `body` と `parsed_response` は HTTParty が断片を
      # つないだ文字列を持っているので正しい。それを Net 側にも戻し、上限なしと同じ見え方にする。
      # ⚠ 本文の無い応答（HEAD・204）は Net 側が nil のままなので触らない。
      def restore_raw_body(response)
        raw = response.response
        raw.body = response.body if raw.body.is_a?(Net::ReadAdapter)
        return response
      end
    end
  end
end
