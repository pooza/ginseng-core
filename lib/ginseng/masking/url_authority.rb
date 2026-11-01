# frozen_string_literal: true

module Ginseng
  module Masking
    # URL の authority の userinfo を落とす (#589 / #661)。⚠ `Masking` に混ぜて使う。
    module UrlAuthority
      # パスワードの無い userinfo を丸ごと落とすスキーム (#661)。Sentry の DSN や `https://<トークン>@github.com/`
      # のように、HTTP では user 部そのものが資格情報になる。⚠ `postgres://app@db` などのユーザ名は診断に要るので残す。
      USERINFO_MASK_SCHEMES = ['http', 'https'].freeze

      private

      # userinfo に埋まったパスワードを落とす (#589)。
      #
      # 🔴 **同じ URL のクエリは落ちるのに、隣にあるパスワードが平文で残っていた。**
      # `postgres://app:S3CRET@db/mydb` のような DSN は例外メッセージに載る
      # （`Sequel.connect` の失敗を `@logger.error(error: e)` で出す経路）。
      #
      # ⚠⚠ **ユーザ名は落とさない（`USERINFO_MASK_SCHEMES` のパスワード無しを除く。#661）。** ユーザ名は診断に要るうえ、
      # 資格情報はパスワードのほう。⚠ `redis://:S3CRET@redis:6379/0` のように**ユーザ名が空**の形も拾う。
      # ⚠ userinfo は**最後の** `@` まで（パスワードに `@` があっても丸ごと落とす）。
      def masked_url_authority(authority, scheme: nil)
        at = authority.rindex('@')
        return authority unless at
        colon = authority.index(':')
        # ⚠ `https://<鍵>:@h` はパスワードが空で、鍵は user 部にある。
        if colon.nil? || colon >= at - 1
          # ⚠ 空白を越えた `@` は後ろの文のメールアドレスかもしれない。ユーザ名として丸ごと落とすと文が消える。
          return authority if authority.match?(/\s/) || !mask_userinfo_user?(scheme)
          return "#{FILTERED}#{authority[at..]}"
        end
        return "#{authority[..colon]}#{FILTERED}#{authority[at..]}"
      end

      def mask_userinfo_user?(scheme)
        return USERINFO_MASK_SCHEMES.include?(scheme.to_s.delete_suffix('://').downcase)
      end
    end
  end
end
