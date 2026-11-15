# frozen_string_literal: true

module Ginseng
  # `host_validator` がホストを通さなかったことを表すエラー (#695 / pooza/ginseng-fediverse#310)。
  #
  # ⚠ **メッセージは `Rejected host '<host>'` で始める（7.0.x までと同じ）。** 利用側に、文言の
  # 前方一致で拒否を見分けているものがある（tomato-shrieker / mulukhiya-toot-proxy）。
  # ⚠ GatewayError を継承するのは、`rescue Ginseng::GatewayError` で受けている利用側を
  # 抜けさせないため。⚠ 再送はしない（検証は `repeat` の外）。
  class RejectedHostError < GatewayError
  end
end
