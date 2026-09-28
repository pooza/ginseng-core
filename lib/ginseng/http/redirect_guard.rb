# frozen_string_literal: true

module Ginseng
  class HTTP
    # 資格情報を運ぶ要求のガード（#653。実装は `ginseng-fediverse` の
    # `Ginseng::Fediverse::RedirectGuard` から移設した。由来は
    # pooza/ginseng-fediverse#280 / #282）。
    #
    # 🔴🔴 **クラスではなく module にして、インスタンスへ prepend する。**
    # ⚠⚠ 初版（fediverse）は `Ginseng::HTTP` のサブクラスだったが、**利用側は全員
    # `Package#http_class` を自前の HTTP へ差し替えている**（gem 側の `Environment` /
    # `Logger` を指さないようにするため）ので、**継承経路に一度も現れず、ガードが
    # 1 本も届いていなかった**。⚠ prepend なら `http_class` が何を返しても効く。
    #
    # ⚠⚠ **挿し方は [HTTP#guard_redirects!](../http.rb) を通す。** 呼び出し側が
    # `singleton_class.prepend` を直に書くと、**クラスへ挿す形と混ざったときに
    # 二重に走る**（実測: 同じ特異クラスへ 2 回は 1 個、クラスと特異クラスの
    # 両方だと 2 個）。⚠ 二重でも実害は無いが、挿し先を 1 つに寄せておく。
    #
    # 🔴🔴 **資格情報を持つ要求ではリダイレクトを追わない。** ⚠⚠ HTTParty の既定は追従で、
    # **ホストをまたいで外すのは `basic_auth` だけ** — `Authorization` は 301 / 302 でも
    # 307 / 308 でも送られ、🔴 **307 / 308 は本文ごと別ホストへ POST し直す**。
    # ⚠ `maintain_method_across_redirects` では塞がらない。
    #
    # ⚠⚠ **口ごとに `follow_redirects: false` を書く形にしない。** 資格情報付きの
    # 口は 50 以上あり、**足すたびに忘れる**。持っているかどうかで決める。
    #
    # ⚠ **資格情報を持たない要求は従来どおり追う。** 🔴 一律に切ると、Google Apps Script
    # のように**相手が正規に 302 を返す経路**が壊れる（`HTTP#get` のコメント参照）。
    #
    # ⚠⚠ **`host_validator` を渡した経路とは別物。** あちらは「オリジンをまたいだら
    # 資格情報を落として追う」（#527 / #568 / #576）。こちらは**宛先が 1 つに
    # 決まっている Service** 向けなので、**落として追う**より**追わない**ほうが合う。
    # ⚠ だから `Ginseng::HTTP` の既定にはしない（pooza/ginseng-style#111 の A を採らない）。
    module RedirectGuard
      # 🔴🔴 **本文を伴うメソッドは、資格情報の有無を問わず追わない（#280 Codex P1）。**
      #
      # ⚠⚠ **本文のキーを列挙しない。** 🔴 列挙すると「口ごとに書く」と同じ失敗に戻る —
      # 実際、`i`（Misskey）だけを見ていた初版は **`appSecret` / `client_secret` /
      # `code` / `code_verifier` を本文に載せる認証の口 4 つを素通りさせていた**。
      # ⚠ このガードを挿す相手は設定された宛先 1 つなので、**書き込みの口で 3xx が
      # 来るのはそれ自体が異常**。
      UNSAFE_METHODS = [:post, :put, :delete].freeze

      [:head, :get].each do |method|
        define_method(method) do |uri, options = {}|
          return guard_response(super(uri, guarded_options(options, uri:)))
        end
      end

      UNSAFE_METHODS.each do |method|
        define_method(method) do |uri, options = {}|
          return guard_response(super(uri, guarded_options(options, safe: false)))
        end
      end

      # ⚠⚠ **`upload` も同じ扱い。** 🔴 添付の口は `Authorization` を持ち、
      # multipart の本文ごと撃ち直されうる。
      #
      # ⚠⚠ **ここで `guarded_options` を挟んでも効かない** — `upload` が multipart 用の
      # hash を組み直すので黙って捨てられる。効いているのは下の `upload_options`。
      # 🔴 したがって **`upload` だけは呼び出し側の明示が通らない**（常に追わない）。
      def upload(uri, file, options = {})
        return guard_response(super)
      end

      # ⚠ **`mkcol` は `Net::HTTP` を直に使うので、そもそもリダイレクトを追わない。**
      # ⚠⚠ **それでも応答は見る** — 3xx を黙って返すと「作れていないのに成功」に
      # なる（#282 が投稿の口で塞いだのと同じ形）。
      # ⚠ この gem の利用側に `mkcol` の呼び出しは実測でゼロ（`ginseng-*` 7 本と
      # アプリ側 4 本を走査）。
      def mkcol(uri, options = {})
        return guard_response(super)
      end

      private

      # 🔴🔴 **`upload` は渡した options をそのまま使わない。** ⚠⚠ multipart 用の hash を
      # **組み直す**ので、`upload` に `follow_redirects` を混ぜても**黙って捨てられる**。
      # 組み立てた**あと**の hash を見て決める。
      def upload_options(file, options)
        return guarded_options(super, safe: false)
      end

      # ⚠ **呼び出し側が明示していたら、そちらを優先する。** 口の側で意図して
      # 追わせている（追わせない）場合に、ここで上書きしない。
      # ⚠ `safe:` はメソッドが GET / HEAD か。本文を伴うメソッドは無条件で切る
      # （上の `UNSAFE_METHODS`）。
      #
      # 🔴🔴 **GET / HEAD でも `body` があれば切る (#653 Codex P1・4 巡目)。**
      # ⚠⚠ **本文のキーは列挙しない**（`UNSAFE_METHODS` と同じ理由）。実測で、
      # `host_validator` を渡した GET に 307 を返すと、**`redirect_options` が
      # `keep_body` で本文を持ち越し、メソッドも GET のまま**なので
      # **`client_secret` が別ホストの 2 段目へ届いた**（validator を渡さない経路では
      # HTTParty が GET の本文を撃ち直さないので届かない）。
      def guarded_options(options, safe: true, uri: nil)
        return options if options.key?(:follow_redirects)
        return options if safe && !credentials?(options, uri) && options[:body].blank?
        return options.merge(follow_redirects: false)
      end

      # ⚠ GET / HEAD ではこれを見る。🔴 `cookies:` は HTTParty があとからヘッダへ移すので、
      # **ヘッダだけ見ていては落とせない**。
      def credentials?(options, uri = nil)
        return true if CREDENTIAL_OPTIONS.any? {|key| options[key].present?}
        return true if credential_headers?(options[:headers])
        return true if userinfo?(uri)
        return credential_query?(options, uri)
      end

      # 🔴🔴 **`https://user:pass@host/` は options に現れない (#653)。** HTTParty が
      # userinfo を `basic_auth` へ移すのは `Request#initialize` の最後なので、ここでは
      # まだ無い。⚠ 実測で、**同じホストの `http://` へ 302 を返されると Basic が平文の
      # まま 2 段目へ再送された**（別ホストなら上流が落とす）。
      # ⚠ `base_uri` 経由では入らない（`create_uri` は scheme / host / port だけ写す）
      # ので、踏むのは絶対 URI を直に渡す口だけ。
      # ⚠⚠ **字面ではなく解析して見る (#653 Codex P1・3 巡目)。** 🔴 初版は
      # `scheme://...@` の**文字列パターン**で見ていたので、**スキーム相対の
      # `//user:pass@host/api` が素通り**した — `create_uri` は `base_uri` から
      # scheme / host / port を補うだけで **userinfo を落とさない**ので、HTTParty は
      # そのまま Basic にする（実測で、同一ホストの `http://` へ 302 を返されると
      # 平文で再送された）。
      def userinfo?(uri)
        return false if uri.nil?
        return uri.userinfo.present? if uri.respond_to?(:userinfo)
        return Ginseng::URI.parse(uri.to_s).userinfo.present?
      rescue StandardError
        # 🔴 読めない URI は安全側（資格情報あり）へ倒す。要求そのものも通らない。
        return true
      end

      # ⚠⚠ **クエリに載った資格情報も「資格情報あり」に数える (#653 Codex P1)。**
      # `?access_token=` の形はヘッダにも `CREDENTIAL_OPTIONS` にも現れないので、
      # 見なければ「資格情報なし」に落ちて**黙って追従する**。
      #
      # ⚠ **ここで止めているのは「別のホストの応答を正しいものとして扱うこと」**で、
      # 🔴🔴 **クエリの値が次のホストへ渡ることではない** — 実測で、`options[:query]`
      # は**リダイレクト先へ再送されない**（GET / POST × 302 / 307 / 308 ×
      # `host_validator` の有無の 8 通りで、2 段目の URI にクエリが付かないことを確認。
      # validator の経路は `redirect_options` が明示的に `except(:query)` している）。
      # ⚠⚠ **ヘッダは渡る**ので、そちらとは危険の質が違う。
      #
      # ⚠⚠ **名前の一覧は `Masking` と共有する。** 「マスクの対象か」と「資格情報か」は
      # 同じ判断なので、🔴 2 つ持つと**片方だけ増えて穴になる**。⚠ 利用側が
      # `/logger/mask_query_params` に足した分もそのまま効く。
      def credential_query?(options, uri = nil)
        names = credential_query_names
        # ⚠ **`default_params` も HTTParty が正式に受けるクエリ**（`query_string` で
        # merge される）。⚠⚠ Array 形（`[[key, value], ...]`）も受ける。
        [options[:query], options[:default_params], uri_query(uri)].each do |query|
          keys = query_keys(query)
          # 🔴 復号できないクエリは安全側（資格情報あり）へ倒す。
          return true if keys.nil?
          return true if keys.any? {|key| names.include?(key)}
        end
        return false
      end

      # ⚠⚠ **どちらの枝も同じ形に正規化する。** 🔴 `@logger` の返り値をそのまま使うと、
      # `mask_query_params` を**シンボルで返す** logger を差されたときに 1 つも一致せず、
      # **クエリの検出が丸ごと無効になる**（リリース前レビューの観点②で実測）。
      def credential_query_names
        names = @logger.respond_to?(:mask_query_params) ? @logger.mask_query_params : Masking::MASK_QUERY_PARAMS
        return names.to_set {|name| name.to_s.downcase}
      end

      # ⚠ **`uri` は文字列でも `URI` でも来る。** 相対パスに付いたクエリ
      # （`/api?access_token=x`）も拾う。
      def uri_query(uri)
        return nil if uri.nil?
        return uri.query if uri.respond_to?(:query)
        src = uri.to_s
        return nil unless src.include?('?')
        return src.split('?', 2).last.split('#', 2).first
      end

      # ⚠⚠ **突き合わせる前に復号する (#653 Codex P1・2 巡目)。** 🔴 `access%5Ftoken`
      # はサーバー側では `access_token` として読まれるので、生の字面で比べると
      # **一致せず「資格情報なし」に落ちる**。
      # ⚠ 壊れたエスケープ（`%zz`）は `nil` を返して、呼び出し側で安全側へ倒す。
      def query_keys(query)
        return query.keys.map {|key| decode_query_key(key)} if query.is_a?(Hash)
        return query.map {|pair| decode_query_key(Array(pair).first)} if query.is_a?(Array)
        return [] unless query.is_a?(String)
        return query.split('&').map {|pair| decode_query_key(pair.split('=').first)}
      rescue ArgumentError
        return nil
      end

      # ⚠ `::URI` と書く。素の `URI` はこの gem の `Ginseng::URI` に解決される。
      def decode_query_key(key)
        return ::URI.decode_www_form_component(key.to_s).strip.downcase
      end

      # ⚠ 判断は `HTTP.credential_header?` に寄せる — `host_validator` の経路
      # （オリジンをまたいだら落として追う）と同じ基準で見る。
      def credential_headers?(headers)
        return false unless headers.is_a?(Hash)
        return headers.any? {|key, value| HTTP.credential_header?(key) && value.present?}
      end

      # ⚠⚠ **3xx を黙って返さない（#282）。** 追わないと決めた以上、3xx は「宛先が違う」
      # の合図。🔴 `Ginseng::HTTP` が例外にするのは 400 以上で、3xx のログも 2xx と
      # 同じ `info` 1 行なので、**応答を検査しない利用側では「送れていないのに成功」
      # と数えられる** — 実例: `tomato-shrieker` の `WebhookShrieker`（`Ginseng::Slack`
      # の子）は `def exec(body); return post(body); end` で、**応答を一度も見ない**。
      #
      # ⚠ **「追従しているから 3xx は返らない」ではない。** 🔴 HTTParty が追うのは
      # `Location` を持つ 3xx だけなので、**`Location` の無い 3xx（300 など）は
      # 追従したままでもここへ来る**。⚠⚠ どちらも「宛先が違う」の合図なので落とす。
      # ⚠ **落とすときは `error` を 1 行残す (#653・リリース前レビュー観点②)。**
      # 🔴 4xx は `repeat` の rescue が `error` を出すが、ここは `repeat` の外なので
      # **`info` の「status 307」1 行しか残らない** — ログだけ見ている運用者には
      # 通常の応答と区別が付かない。
      def guard_response(response)
        code = response.respond_to?(:code) ? response.code : nil
        code = code.to_i if code.is_a?(String)
        return response unless code.is_a?(Integer)
        return response unless code.between?(300, 399)
        return response if code == NOT_MODIFIED
        @logger.error(error: 'redirect refused', status: code, location: redirect_target(response))
        return bad_response!(response)
      end

      # ⚠ `Location` の無い 3xx（300 など）もここへ来るので、無ければ `nil`。
      def redirect_target(response)
        return nil unless response.respond_to?(:headers)
        return response.headers['location']
      rescue StandardError
        return nil
      end
    end
  end
end
