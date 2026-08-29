# frozen_string_literal: true

module Ginseng
  module Masking
    # URL の**パス**に埋まった資格情報を落とす一式 (#580)。⚠ `Masking` から
    # 切り出してある (#610) — **`Masking` に混ぜて使う前提**で、`@config` も
    # `mask_url_paths` も混ぜた側が持つ。
    #
    # ⚠⚠ **クエリと違い、パスは「キー名」で判定できない。** 接頭辞を知っている
    # 側が申告するほかないので、`/logger/mask_url_paths` の一覧と突き合わせて
    # **次の 1 セグメントだけ**を伏せる。
    #
    # 🔴 **範囲の重なりの扱いが、この一式の本体。** #607 で Codex が 5 巡し、
    # P1 3 件 / P2 2 件が**全部この範囲**に出た（打ち消し合い・二重置換・O(k²)）。
    module UrlPath
      private

      # 当たった接頭辞。⚠ 既定と設定を合成するので、1 本の URL に複数当たる。
      def mask_url_prefixes(value)
        return mask_url_paths.select {|v| value.include?(v)}
      end

      # 当たった接頭辞が占める範囲を `[接頭辞, 範囲]` で返す。
      # ⚠ **同じ接頭辞が 2 回出ることもある**（重なって出ることもある）。
      def mask_url_prefix_ranges(value)
        return mask_url_prefixes(value).flat_map do |prefix|
          ranges = []
          offset = 0
          while (index = value.index(prefix, offset))
            ranges.push([prefix, index...(index + prefix.length)])
            offset = index + 1
          end
          ranges
        end
      end

      # 伏せる 1 セグメントの範囲を、当たった接頭辞ごとに集める（Codex P1 ×3）。
      #
      # ⚠⚠ **当たった接頭辞は全部落とす。** 1 つ目で切り上げると、
      # `/hook/SECRET1/mulukhiya/webhook/SECRET2` で既定の側だけが伏さり、
      # **合成前は設定 `/hook/` が伏せていた `SECRET1` が平文で残る** ＝
      # 「マスクしない方向へは倒さない」が破れる。
      #
      # 🔴 **ただし、他の接頭辞と重なるセグメントは伏せない。** 重なる接頭辞は
      # 同じ位置から始まるとは限らず、伏せる位置がずれると**秘密のほうが残る**:
      #
      # | 例（設定 `/webhook/special/` ＋ 既定 `/mulukhiya/webhook/`） | 重なり |
      # | --- | --- |
      # | `/mulukhiya/webhook/special/SECRET` | 既定の次の 1 セグメントは `special` ＝ 設定の接頭辞の一部 |
      #
      # ⚠ この規則は対称なので、**どちらを先に見ても結果が変わらない**（並び順でも
      # 長さでも決められなかったのは、当たったうちの 1 つだけを選ぼうとしていたから）。
      #
      # 🔴 **重なりを見るのは「別の接頭辞」だけ。** 同じ接頭辞どうしで重なりを見ると、
      # `/hook/hook/SECRET/` のように**セグメントが接頭辞と同じ綴りの URL** で
      # 両方の出現が互いを打ち消し、**1 つも伏せない**（ランダムな URL を通して実測）。
      # ⚠ 同じ接頭辞の出現は同じ具体度なので、優先も抑制もしない。
      def mask_url_secret_ranges(path)
        # ⚠ **落とせない接頭辞で諦めないこと。** 次が空（`/webhook/` で終わる URL
        # など）なら、その接頭辞だけを飛ばす。
        #
        # 🔴 **抑制してよいのは、自分が実際に伏せる接頭辞だけ（Codex P1）。** 次が
        # 空の当たりに他の接頭辞を止めさせると、**どちらも伏せない**形ができる
        # （設定 `/webhook/special/` ＋ `/mulukhiya/webhook/special/` で実測）。
        # ⚠ だから、重なりを見る前に「伏せるものがある当たり」だけに絞る。
        candidates = mask_url_prefix_ranges(path).filter_map do |prefix, range|
          head = range.end
          tail = path.index('/', head) || path.length
          next if tail <= head
          [prefix, range.begin, head...tail]
        end
        # ⚠ 接頭辞ごとの出現位置（昇順）。重なりの検査で毎回なめないため。
        starts = candidates.group_by(&:first).transform_values {|v| v.map {|_, i, _| i}}
        secrets = candidates.filter_map do |prefix, _index, secret|
          next if overlapping_prefix?(starts, prefix, secret.begin, secret.end)
          secret
        end
        return merge_ranges(secrets)
      end

      # `[head, tail)` に重なる**別の**接頭辞の出現があるか。
      #
      # 🔴 **総なめにしない（Codex P2）。** 同じ接頭辞が k 回出る URL では
      # `v != prefix` が全部外れるので毎回最後まで走り、**ログ 1 行が O(k²) になる**
      # （実測: `/hook/x` を 3,200 回並べた 22KB の URL で **0.48 秒**）。⚠ URL は
      # 例外メッセージ経由で外から長さを選べる。
      #
      # ⚠ 出現位置は昇順なので二分探索で足りる。重なる条件は
      # `出現位置 ∈ (head - 接頭辞の長さ, tail)`。
      def overlapping_prefix?(starts, prefix, head, tail)
        return starts.any? do |other, indexes|
          next false if other == prefix
          index = indexes.bsearch {|v| v > head - other.length}
          index && index < tail
        end
      end

      # 重なる範囲を畳む。
      #
      # 🔴 **同じ範囲を 2 回置き換えると URL が壊れる（Codex P2）。** 終わりが同じ
      # 接頭辞（設定 `/webhook/` と既定 `/mulukhiya/webhook/`）は**同じセグメントを
      # 指す**ので、そのまま 2 回置き換えると元のパスの位置で長さの変わった文字列を
      # 切ることになり、`[FILTERED]LTERED]` のような形になる（⚠ 秘密が長ければ
      # 後ろのパスが消える）。
      def merge_ranges(ranges)
        return ranges.sort_by(&:begin).each_with_object([]) do |range, merged|
          last = merged.last
          if last && range.begin < last.end
            merged[-1] = last.begin...[last.end, range.end].max
          else
            merged.push(range)
          end
        end
      end

      # パスに埋まった資格情報を落としたパスを返す。落とすものが無ければ nil (#580)。
      #
      # 🔴 **モロヘイヤの webhook は digest を知っていれば誰でも投稿できる。**
      # tomato-shrieker の本番では、成功した POST のたびに
      # `{"method":"POST","url":"https://.../mulukhiya/webhook/<digest>","status":200}`
      # が平文で syslog に出ていた（2026-08-25 の当日ログで 22 行）。
      #
      # ⚠ **伏せるのは接頭辞の次の 1 セグメントだけ。** 以降のパスは残す。
      def masked_url_path(uri)
        path = uri.path
        ranges = mask_url_secret_ranges(path)
        return nil if ranges.empty?
        masked = path.dup
        # ⚠ **後ろから置き換える。** 前から置き換えると、残りの範囲の位置がずれる。
        ranges.sort_by {|v| -v.begin}.each {|v| masked[v] = FILTERED}
        return masked
      end
    end
  end
end
