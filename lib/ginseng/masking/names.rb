# frozen_string_literal: true

module Ginseng
  module Masking
    # 資格情報として読む名前の既定値 (#738)。⚠ `Masking` に混ぜて使う。
    #
    # ⚠ `Metrics/ModuleLength` が `Masking` の上限に達したので、一覧だけをここへ出した。
    # 定数は include した先から引けるので、`Masking::MASK_FIELDS` も `Masking` の中の
    # `MASK_FIELDS` も、これまでどおり解決される。
    module Names
      # Hash のキーに現れたら値ごと落とす資格情報の既定値。
      # config の `/logger/mask_fields` で**足せる**（⚠ 減らせない。masking_list 参照）。
      #
      # ⚠ **既定を空にしないこと。** 設定を書き忘れたアプリが守られる状態を既定に
      # する（mask_query_params と同じ判断）。
      #
      # 🔴 **mask_query_params より狭かった (#586)。** URL のクエリに
      # `access_token=` が出れば落ちるのに、Hash のキーが `access_token:` だと
      # 素通りしていた。**同じ資格情報が、通り道によって守られたり守られなかったり
      # する**状態だった。
      #
      # ⚠⚠ **`code` / `i` / `key` は入れない。** クエリのパラメータ名としては
      # 資格情報だが、**Hash のキーとしては無関係な値が普通に入る**（`key` は
      # 汎用名、`code` はステータスコードやエラーコード）。クエリと同じ広さが
      # 正しいとは限らない。⚠ `sig` / `signature` / `hm` / `jwt`（#690 / #693）も
      # クエリ側にだけ在る（理由は `MASK_QUERY_PARAMS`）。
      MASK_FIELDS = [
        'access_token',
        'api_key',
        'apikey',
        # ⚠ HTTP ヘッダの綴りそのもので、資格情報以外の用途が無い。
        'authorization',
        'client_secret',
        'password',
        'refresh_token',
        'secret',
        'token',
        # ⚠ 署名付き URL の名前のうち、**Hash のキーとしても他の用途が無いもの**（#693）。
        # `sig` / `signature` は入れない（無関係な値が普通に入る）。
        'x-amz-security-token',
        'x-amz-signature',
        'x-goog-signature',
        # ⚠ 同じ判断で足した名前（#701）。ヘッダの綴り（`X-Api-Key`）・OIDC の `id_token`・
        # Alibaba OSS / Tencent COS の署名。⚠⚠ `auth` / `hmac` は入れない（Hash のキーとしては
        # 設定値やアルゴリズム名が普通に入る）。
        'api-key',
        'id_token',
        'q-signature',
        'security-token',
        'x-api-key',
        'x-cos-security-token',
        'x-oss-security-token',
        'x-oss-signature',
        # 🔴 **クエリでは伏せるのに Hash のキーでは平文だった (#738)。** `accessToken` は Misskey の
        # MiAuth の応答のキーそのもの（mulukhiya が `parsed_response['accessToken']` で受ける）。
        # 照合は小文字化するので、camelCase は区切りの無い綴りで当たる。
        'access-token',
        'accesstoken',
        'api_token',
        'private_token',
        # ⚠ 近い名前も同じ並びで足す (#738)。⚠ クエリの一覧には 6.0.0 で足した。⚠⚠ `pwd` は入れない
        # （Hash のキーや `pwd: /path` の文では作業ディレクトリを指す。クエリ側にだけ在る）。
        'api-token',
        'apitoken',
        'auth-token',
        'auth_token',
        'authtoken',
        'private-token',
        'privatetoken',
      ].freeze

      # URL のクエリに現れたら落とす資格情報パラメータの既定値。
      # config の `/logger/mask_query_params` で**足せる**（⚠ 減らせない）。
      #
      # 🔴 **署名付き URL の名前を持っていなかった (#690)。** 第三者が渡す URL
      # （webhook の `image_url` など）は署名付きのことがあり、**署名はその 1 オブジェクトへの
      # 期限付きの持参人払い**。⚠ 照合は小文字化して行うので、`X-Amz-Signature` も
      # CloudFront の `Signature` もここの綴りで一致する。
      #
      # ⚠ **鍵の識別子（`X-Amz-Credential` / `Key-Pair-Id`）は入れない。** 秘密ではなく、
      # どの鍵の URL かはログに残したい。
      # ⚠ **署名付き URL に限らない名前も足した (#693)。** `hm`（Discord 添付の HMAC）と
      # `jwt`（GitHub の private 添付）は webhook の `image_url` に現実に来る。
      # `authorization` は `MASK_FIELDS` に在るのにここに無かった（Backblaze B2 は
      # クエリで受ける。#586 が塞いだ非対称の逆向き）。
      # ⚠⚠ **`sig` / `signature` / `hm` / `jwt` は `MASK_FIELDS` に足さない。** Hash のキーとしては
      # 無関係な値が普通に入る（`code` / `key` と同じ判断）。⚠ `x-amz-*` / `x-goog-*` は
      # Hash のキーとしても他の用途が無いので、あちらにも在る（#693）。
      #
      # ⚠⚠ **`HTTP::RedirectGuard` が同じ一覧を「資格情報か」の判定に使う。** ここへ足すと、
      # ガードを挿した口では、その名前をクエリに持つ GET / HEAD がリダイレクトを追わず、
      # 🔴 **3xx が `GatewayError` になる**。⚠ 呼び出し側が `follow_redirects:` を
      # 明示していれば従来どおり。
      #
      # ⚠ **#701 で足した名前:** `api-key` / `x-api-key` / `auth`（Firebase など）/ `id_token`（OIDC）/
      # `hmac`、Alibaba OSS（`security-token` / `x-oss-*`）、Tencent COS（`q-signature` /
      # `x-cos-security-token`）、Akamai（`hdnts` / `__token__`）。⚠⚠ `s`（imgix）/ `t`（Slack）/
      # `oh`（Facebook）は汎用すぎるので入れない。
      #
      # 🔴 **近い名前が素通りしていた (#738)。** `MASK_FIELDS` には 5.1.0 で足したが、ここは
      # `RedirectGuard` の判定も変わる（major）ので 6.0.0 で足した。camelCase（`authToken`）は
      # 小文字化して区切りの無い綴りで当たる。⚠ `pwd` はここにだけ在る — Zoom の参加 URL の
      # パスコード（`/j/123?pwd=…`）。⚠ ファイルマネージャの `?pwd=/path` のように作業ディレクトリを
      # 指すこともあるが、当たっても伏せすぎ・追わないだけで安全側に倒れる。
      MASK_QUERY_PARAMS = [
        '__token__',
        'access-token',
        'access_token',
        'accesstoken',
        'api-key',
        'api-token',
        'api_key',
        'api_token',
        'apikey',
        'apitoken',
        'auth',
        'auth-token',
        'auth_token',
        'authorization',
        'authtoken',
        'client_secret',
        'code',
        'hdnts',
        'hm',
        'hmac',
        'i',
        'id_token',
        'jwt',
        'key',
        'password',
        'private-token',
        'private_token',
        'privatetoken',
        'pwd',
        'q-signature',
        'refresh_token',
        'secret',
        'security-token',
        'sig',
        'signature',
        'token',
        'x-amz-security-token',
        'x-amz-signature',
        'x-api-key',
        'x-cos-security-token',
        'x-goog-signature',
        'x-oss-security-token',
        'x-oss-signature',
      ].freeze

      # URL の**パス**に現れたら次の 1 セグメントを落とす接頭辞の既定値。
      # config の `/logger/mask_url_paths` で**足せる**（⚠ 減らせない）(#580)。
      #
      # ⚠⚠ **クエリと違い、パスは「キー名」で判定できない。** モロヘイヤの
      # webhook は `POST /mulukhiya/webhook/{digest}` で **パスそのものが
      # 資格情報**なので、接頭辞を知っている側が申告するほかない。
      #
      # ⚠ **既定を空にしないこと。** mask_query_params と同じく「設定が無ければ
      # 既定へ倒す。マスクしない方向へは倒さない」。モロヘイヤ配下のアプリが
      # 設定を書き忘れても守られる状態を既定にする。
      MASK_URL_PATHS = [
        '/mulukhiya/webhook/',
      ].freeze
    end
  end
end
