# frozen_string_literal: true

module Ginseng
  class GatewayError < Error
    # source_body が JSON パースを試みるボディの上限。
    MAX_SOURCE_BODY_BYTES = 65_536

    # 上流のレスポンスそのもの。HTTP が raise する際に添える。
    #
    # これが無いと、受け側は `"Bad response NNN"` という文字列しか手に入らず、
    # 上流が返した理由（Misskey の `TOO_MANY_DRAFTS`、Mastodon の
    # `Validation failed: ...` 等）がプロキシの中で失われる
    # (mulukhiya-toot-proxy#4480)。**添えるだけで、メッセージ書式は変えない。**
    attr_accessor :response

    def status
      return 502
    end

    # 上流が返したステータス。
    #
    # response があればそれを正とする。無い場合（タイムアウトや接続失敗を
    # 包み直したもの、旧来の raise 箇所）は従来どおりメッセージから復元し、
    # 取り出せなければ status = 502 に倒す。
    # ⚠ `match` は nil を返しうる。`&.` を落とすと、もっとも起きやすい失敗
    # （相手が落ちている）で NoMethodError が本来の例外に被さる。
    def source_status
      return response.code.to_i if response.respond_to?(:code) && response.code
      return status unless (matched = message.match(/ ([[:digit:]]{3})$/))
      return matched[1].to_i
    end

    # 上流のボディを JSON として読めたら Hash / Array で返す。読めなければ nil。
    #
    # ⚠ **JSON として読めた場合のみ**返す。上流が nginx の HTML エラーページを
    # 返すこともあり、それを素通しするとプロキシが他人の HTML を吐くことになる。
    # サイズ上限も掛ける（巨大なエラーページを丸ごとパースしない）。
    # ⚠ メモ化は max_bytes ごとに持つ。上限を変えて呼び直したときに前の結果を
    # 返してしまうと、上限の意味が消える。nil も結果なので key? で判定する。
    def source_body(max_bytes: MAX_SOURCE_BODY_BYTES)
      @source_body ||= {}
      return @source_body[max_bytes] if @source_body.key?(max_bytes)
      return @source_body[max_bytes] = parse_source_body(max_bytes)
    end

    private

    def parse_source_body(max_bytes)
      body = response&.body.to_s
      return nil if body.empty? || body.bytesize > max_bytes
      parsed = JSON.parse(body)
      return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
      return nil
    rescue JSON::ParserError
      return nil
    end
  end
end
