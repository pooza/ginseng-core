# frozen_string_literal: true

module Ginseng
  # 検証で通した IP へ接続を固定できないことを表すエラー
  # (pooza/mulukhiya-toot-proxy#4524)。
  #
  # ⚠ **再送してはいけない。**プロキシ設定は試行の間に変わらないので、
  # 再送しても同じ場所で落ちるだけ（HTTP#retryable? が明示的に false を返す）。
  # GatewayError を継承するのは、呼び出し側の rescue を増やさないためと、
  # 「上流へ到達できなかった」という意味づけが同じため。
  class PinningError < GatewayError
  end
end
