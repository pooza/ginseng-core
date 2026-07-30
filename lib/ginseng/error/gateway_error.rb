# frozen_string_literal: true

module Ginseng
  class GatewayError < Error
    def status
      return 502
    end

    # 上流が返したステータス。取り出せない message（タイムアウトや接続失敗を
    # 包み直したものなど）では status = 502 に倒す。
    # ⚠ `match` は nil を返しうる。`&.` を落とすと、もっとも起きやすい失敗
    # （相手が落ちている）で NoMethodError が本来の例外に被さる。
    def source_status
      return status unless (matched = message.match(/ ([[:digit:]]{3})$/))
      return matched[1].to_i
    end
  end
end
