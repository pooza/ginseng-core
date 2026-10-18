# frozen_string_literal: true

module Ginseng
  module Masking
    # URL の**クエリとフラグメント**に埋まった資格情報を落とす一式（入れ子の URL・シェルのエスケープを
    # 含む）。⚠ `Masking` から切り出してある (#712) — **`Masking` に混ぜて使う前提**で、
    # `mask_query_params` も `mask_url_core` も混ぜた側が持つ（`UrlPath` と同じ形）。
    module UrlQuery
      # クエリとフラグメントの `名前=値` 1 つ (#700)。区切りは `masked_url_params` を見る。
      #
      # 🔴🔴 **`;` と `?` は、次に `名前=` が続くときだけ区切りとみなす（Codex P1）。** どちらも
      # 値の中に普通に現れる文字なので、無条件に切ると `token=SEC;RET` が `token=[FILTERED];RET`
      # になり、**資格情報の後ろ半分が残っていた**（パースしていたころは値ごと落ちていた）。
      # ⚠ `&amp;X-Amz-Signature=` / `a=1;sig=` / `redirect=https://x/?token=` は、後ろに
      # `名前=` が続くので従来どおり切れる。
      #
      # ⚠ 区切りの 1 文字も一致に含める（`masked_url_params` が、伏せた値の後ろの一致を区切りごと消すため）。
      # ⚠ キーは「空白で切るか」（`true` は文中の URL、`false` は引数まるごとが URL）。
      URL_PARAM_PATTERNS = {true => '\s', false => ''}.to_h do |text, stop|
        pattern = /
          (?<sep>[?&;\#]) (?<name>[^?&;\#=#{stop}]*) =
          (?: [^?&;\##{stop}] | [?;] (?![^?&;\#=#{stop}]*=) )*
        /x
        [text, pattern]
      end.freeze

      # 資格情報の値の終わり (#712)。⚠⚠ **`;` と `?` では終えない。** 値の中の `;名前=` で切ると
      # `token=SEC;a=RET` の `RET` が残る（#700 の Codex P1 の trade-off）。⚠ Rack 3 は `;` で区切らない
      # ので、サーバーが読む値は `&` か `#` までで、伏せすぎて困るのは診断の側だけ。
      URL_CREDENTIAL_END_PATTERNS = {true => /[&\#\s]/, false => /[&\#]/}.freeze

      # 入れ子の URL（`?u=https://…`）を何段まで追うか (#712)。⚠ 超えたら値ごと伏せる（安全側）。
      MAX_NESTED_URL_DEPTH = 4

      private

      # 🔴 **シェルのエスケープを外した形でも伏せる (#712)。** `https://h/x\?token\=SECRET` は、
      # 区切りがエスケープされているので `?token=` として読めなかった（`sh -c` の文字列）。
      # ⚠ 外した形で伏せるものがあったときだけ、**エスケープし直して**返す（伏字は読める形に戻す）。
      # 伏せるものが無ければ元の文字列のまま。⚠ 生のまま伏せた結果で足りる（エスケープを外すと
      # 外した形で伏せた結果と同じになる）ときも、元の形のまま返す。
      #
      # 🔴 **エスケープした空白は、外すときに目印（英数字）へ置き換える（Codex P1）。** 素の空白に戻すと、
      # 文中の URL として空白で切られ、`token\=SEC\ RET` の `RET` が残った。⚠ 素の空白はこれまでどおり
      # URL の終わりの目印として読む。伏せたあとで目印を空白に戻す。
      def mask_escaped_url(value, text:, depth:)
        plain = mask_plain_url(value, text:, depth:)
        marker = "GINSENGBLANK#{SecureRandom.hex(8)}"
        unescaped = unescape_shell(value, marker)
        masked = mask_plain_url(unescaped, text:, depth:)
        return plain if masked == unescaped || masked == unescape_shell(plain, marker)
        masked = masked.gsub(/#{marker}(\d+)x/) {Regexp.last_match(1).to_i.chr}
        return masked.shellescape.gsub(FILTERED.shellescape, FILTERED)
      end

      # ⚠ 改行は `'\n'` の形でも来る（`Shellwords.escape` が改行だけをそう表す）。
      def unescape_shell(value, marker)
        return value.gsub(/\\(.)|'(\n)'/m) do
          char = Regexp.last_match(1) || Regexp.last_match(2)
          char.match?(/\s/) ? "#{marker}#{char.ord}x" : char
        end
      end

      # クエリとフラグメントの `名前=値` のうち、名前が当たる値を落とす。
      #
      # ⚠ **区切りは `?` `&` `;` `#`。** `;` を入れると `&amp;` も `amp` と次の名前に
      # 分かれる（HTML やフィードから来た URL）。⚠ フラグメントも見る — OAuth の implicit
      # flow は `#access_token=` で返す。⚠ 値の中の `?` でも切る（`redirect=https://x/?token=`
      # の内側も伏せる）。いずれも**切りすぎて困るのは「伏せすぎ」の側**だけ。
      # ⚠ 文中の URL では、値は空白でも終わる（`url:` に空白の混じった URL が来たとき、後ろの文まで
      # 伏せない）。
      #
      # 🔴 **資格情報の値は `&` か `#` まで伏せる (#712)。** 区切りの規則（`URL_PARAM_PATTERNS`）で
      # 値を終えると、値の中の `;名前=` / `?名前=` で切れて後ろ半分が残った。
      # 🔴 **ほかの値は、入れ子の URL として伏せる (#712)。** `?u=https://x/mulukhiya/webhook/SECRET`
      # のパスは、外側のパスではないので見ていなかった。
      #
      # ⚠⚠ **`gsub` で回す。** `Regexp#match(rest, pos)` のループは長さの 2 乗に近く伸びた（32 万字で
      # 1.3 秒、`gsub` は 0.09 秒）。伏せた値の終わり（`zone`）より手前で始まる一致は、区切りごと消す
      # （その範囲は一致で埋まり、間に残る文字は無い — 値は `&` `#`（文中では空白も）で必ず終わるので）。
      def masked_url_params(rest, text:, depth:)
        return rest if rest.empty?
        zone = -1
        return rest.gsub(URL_PARAM_PATTERNS[text]) do
          match = Regexp.last_match
          head = match.byteoffset(0).first
          next '' if head < zone
          key = "#{match[:sep]}#{match[:name]}="
          if mask_query_param?(match[:name])
            zone = rest.byteindex(URL_CREDENTIAL_END_PATTERNS[text], head + 1) || rest.bytesize
            # ⚠ 値が空でも `[FILTERED]` にする（#700 より前と同じ形）。
            next "#{key}#{FILTERED}"
          end
          "#{key}#{masked_nested_url(match[0][key.length..], text:, depth:)}"
        end
      end

      # クエリの値に入れ子になった URL を伏せる (#712)。
      #
      # ⚠ 生の URL（`?u=https://…`）と、エンコードした URL（`?u=https%3A%2F%2F…`）の両方。エンコード
      # した形は復号して伏せ、伏せるものがあったときだけエンコードし直す（伏字は読める形に戻す）。
      # ⚠⚠ **段数に上限を置く** — 1 段ごとに値を読み直すので、入れ子を重ねた入力で計算量が増える。
      # 超えたら値ごと伏せる。
      def masked_nested_url(value, text:, depth:)
        return value unless value.include?('://') || value.include?('%')
        return FILTERED if depth >= MAX_NESTED_URL_DEPTH
        return mask_url_core(value, text:, depth: depth + 1) if value.match?(URL_PATTERN)
        decoded = decode_nested_url(value)
        return value if decoded.nil? || decoded == value
        masked = masked_nested_url(decoded, text: false, depth: depth + 1)
        return value if masked == decoded
        return ::URI.encode_www_form_component(masked).gsub(FILTERED_ENCODED, FILTERED)
      end

      # ⚠ 復号できない値・復号すると不正なバイト列になる値は、エンコードした URL ではない（`nil`）。
      def decode_nested_url(value)
        decoded = ::URI.decode_www_form_component(value)
        return decoded if decoded.valid_encoding?
        return nil
      rescue ArgumentError, EncodingError
        return nil
      end

      # ⚠⚠ **名前は復号し、配列の添字を外してから照合する (#700)。** `access%5Ftoken` も
      # `sig[]` もサーバー側では `access_token` / `sig` として読まれる。🔴 復号できない名前は
      # 伏せる側に倒す（`RedirectGuard` と同じ）。
      # 🔴 **`EncodingError` も受ける（3.0.0 リリース前レビュー）。** 復号した名前が不正な UTF-8 だと
      # `Encoding::CompatibilityError` が上がり、包み直した例外のクラスが変わって `cause` に平文が残った。
      def mask_query_param?(key)
        return mask_query_params.include?(Masking.query_param_name(key))
      rescue ArgumentError, EncodingError
        return true
      end
    end
  end
end
