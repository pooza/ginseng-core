# frozen_string_literal: true

module Ginseng
  # ホストの名前が解決できなかったために、検証で通せなかったことを表すエラー (#695)。
  #
  # ⚠⚠ **「拒否」と「解決できない」を分けるためのもの。** どちらも fail-closed で通さないが、
  # 前者は相手（か設定）の問題で、後者は一時的な DNS の揺れでありうる — 利用側はやり直しと
  # 監視の扱いを分けたい（pooza/tomato-shrieker#1785）。
  # ⚠ 解決できない、には NXDOMAIN も入る。`Resolv::DNS#getaddresses` は応答の無いネーム
  # サーバーでも NXDOMAIN でも空配列を返し、区別できない（実測・2026-11-15）。
  # ⚠ RejectedHostError を継承する（通さなかったことに変わりはない。メッセージも
  # `Rejected host '<host>'` で始まる）。⚠ この gem は再送しない。やり直すかは利用側が決める。
  class HostResolutionError < RejectedHostError
  end
end
