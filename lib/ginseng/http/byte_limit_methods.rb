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
      # 中断できる（メモリは max_bytes + 断片 1 つぶんで頭打ちになる）。
      def execute(method, uri, options, max_bytes = nil)
        return HTTParty.public_send(method, uri.normalize, options) unless max_bytes
        received = 0
        return HTTParty.public_send(method, uri.normalize, options) do |fragment|
          received += fragment.bytesize
          next if received <= max_bytes
          raise TooLargeError, "Response body exceeded #{max_bytes} bytes (#{uri})"
        end
      end
    end
  end
end
