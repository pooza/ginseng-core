# frozen_string_literal: true

module Ginseng
  module Masking
    # **ホストを決めて**、パスの接頭辞から後ろを全部落とす一式 (#704)。⚠ `UrlPath` と同じく
    # `Masking` に混ぜて使う前提で、`@config` は混ぜた側が持つ。
    #
    # 🔴 **`UrlPath`（`/logger/mask_url_paths`）では塞がらない。** あちらは接頭辞の**次の
    # 1 セグメントだけ**を伏せるので、Slack の incoming webhook
    # （`/services/T…/B…/<秘密>`）は 3 セグメントめの秘密が残る。⚠ 公開の設定なので、
    # 既存の項目の意味は変えずに別のリスト（`/logger/mask_url_host_paths`）にした。
    #
    # ⚠ **ホストは必須。** `/services/` だけでは無関係な URL も巻き込む。
    module UrlHostPath
      # **ホストを決めて**、パスの接頭辞から後ろを全部落とす規則の既定値 (#704)。config の
      # `/logger/mask_url_host_paths` で**足せる**（⚠ 減らせない）。書き方は `ホスト/パスの接頭辞`。
      #
      # 🔴 **webhook の URL はパスそのものが資格情報で、秘密は接頭辞の 1 セグメント先とは限らない。**
      # - Slack の incoming webhook: `https://hooks.slack.com/services/T…/B…/<秘密>`。⚠ ワークフローの
      #   webhook（`/workflows/` / `/triggers/`）と、GovSlack（`hooks.slack-gov.com`）も同じ（4.2.0 リリース前レビュー）
      # - Discord の webhook: `https://discord.com/api/webhooks/{id}/{token}`。⚠ 版付きのパス
      #   （`/api/v10/webhooks/`）と、`canary` / `ptb` のサブドメインがある。どちらも旧ドメイン `discordapp.com` にもある
      MASK_URL_HOST_PATHS = [
        *['hooks.slack.com', 'hooks.slack-gov.com']
          .product(['services/', 'workflows/', 'triggers/']),
        *['discord.com', 'discordapp.com'].flat_map {|v| [v, "canary.#{v}", "ptb.#{v}"]}
          .product(['', 'v6/', 'v7/', 'v8/', 'v9/', 'v10/'].map {|v| "api/#{v}webhooks/"}),
      ].map {|host, path| "#{host}/#{path}"}.freeze

      private

      # 設定と合成した規則。⚠ 要素は `ホスト/パスの接頭辞`（`hooks.slack.com/services/`）。
      # ⚠ `https://` を付けて書いても読む。パスが無ければ（`example.com`）パス全体を落とす。
      def mask_url_host_paths
        return masking_list('/logger/mask_url_host_paths', MASK_URL_HOST_PATHS) do |entries|
          rules = entries.filter_map {|entry| mask_url_host_path_rule(entry)}.uniq
          {rules:, hosts: Regexp.union(rules.map(&:first).uniq.map {|v| /#{Regexp.escape(v)}/i})}
        end
      end

      # `[ホスト（小文字）, パスの接頭辞に当たる正規表現]`。
      #
      # ⚠ **連続したスラッシュは 1 つとして見る**（`UrlPath` の #712 と同じ。nginx の `merge_slashes`）。
      # ⚠ **大文字小文字を区別しない** — 違う綴りを相手が受けるかは相手次第なので、伏せる方へ倒す。
      def mask_url_host_path_rule(entry)
        entry = entry.to_s.strip.sub(%r{\A[a-z][a-z0-9+.-]*://}i, '')
        host, slash, path = entry.partition('/')
        host = normalize_mask_host(host)
        return nil if host.empty?
        segments = "#{slash}#{path}".squeeze('/').split('/', -1).map {|v| Regexp.escape(v)}
        segments = ['', ''] if segments.empty?
        return [host, /\A#{segments.join('/+')}/i]
      end

      # ⚠ userinfo とポートを外し、小文字にして末尾の `.` を落とす。
      def normalize_mask_host(authority)
        host = authority.sub(/\A.*@/m, '').sub(/:\d*\z/, '')
        return host.downcase.delete_suffix('.')
      end

      # ⚠ HTTP#log は毎リクエスト通る。ホストの綴りがどこにも無い URL では何もしない。
      def mask_url_host_candidate?(value)
        return mask_url_host_paths[:hosts].match?(value)
      end

      # パスの規則を全部掛けたパス（落とすものが無ければ元のまま）。
      # ⚠ ホストの規則が当たれば接頭辞から後ろは全部落ちるので、`UrlPath` の規則は見ない。
      def masked_url_paths(authority, path)
        return masked_url_host_path(authority, path) || masked_url_path(path) || path
      end

      # 接頭辞から後ろを `[FILTERED]` 1 つにしたパスを返す。落とすものが無ければ nil。
      #
      # ⚠ **接頭辞は残す**（どこへ送ったかは読めるように）。接頭辞で終わる URL（後ろが空）は
      # 落とすものが無いので触らない。⚠ 伏せないところは 1 バイトも変えない。
      def masked_url_host_path(authority, path)
        host = normalize_mask_host(authority)
        ends = mask_url_host_paths[:rules].filter_map do |rule_host, pattern|
          next unless rule_host == host
          match = pattern.match(path)
          match&.end(0)
        end
        head = ends.min
        return nil if head.nil? || head >= path.length
        return "#{path[0...head]}#{FILTERED}"
      end
    end
  end
end
