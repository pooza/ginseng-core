# frozen_string_literal: true

module Ginseng
  # 応答が受信バイト数の上限を超えたことを表すエラー (#526)。
  #
  # ⚠ **再送してはいけない。**相手が同じものを返す限り同じ場所で超えるだけで、
  # 再送のたびに上限ぶんの転送とメモリを食う（HTTP#retryable? が明示的に
  # false を返す）。GatewayError を継承するのは PinningError と同じ理由で、
  # 呼び出し側の rescue を増やさないため。
  class TooLargeError < GatewayError
  end
end
