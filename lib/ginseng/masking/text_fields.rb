# frozen_string_literal: true

module Ginseng
  module Masking
    # 文字列の中の `key=value` / `key: value` を落とす (#661)。
    # ⚠ `Masking` に混ぜて使う。`mask_fields` はあちらに在る。
    module TextFields
      private

      # 文字列の中の `key=value` / `key: value` の値を落とす (#661)。
      #
      # 🔴 **URL の形でないものは素通りしていた。** 改行で切れた URL の後半（`b?token=SECRET`。#717）も同じ。
      # ⚠ **名前は `mask_fields`。** クエリの一覧には `key` / `code` / `i` が在り、文章を壊すので使わない。
      # ⚠ `mask_urls_in` には入れない。あちらは URL だけを見る口で、`mask` より細かい経路でも呼ばれる。
      # 🔴 値に改行が混じると 1 行目までしか落とせない（文の続きと区別できない）。
      def mask_fields_in(text)
        return text unless text.include?('=') || text.include?(':')
        return text.gsub(mask_fields_pattern) {"#{Regexp.last_match[:head]}#{FILTERED}"}
      end

      # ⚠ `mask_fields` は設定が変わらない限り同じオブジェクトを返すので、それを memo の鍵にする。
      def mask_fields_pattern
        fields = mask_fields
        return @mask_fields_pattern.last if @mask_fields_pattern&.first.equal?(fields)
        # ⚠ `Regexp.union` は埋め込むと `(?-mix:…)` になり、外側の `i` が効かない。
        names = fields.map {|field| Regexp.escape(field)}.join('|')
        pattern = /
          (?<head> (?<![a-z0-9_-]) (?:#{names}) ["']? \s* (?: = | :(?!:) ) \s* )
          (?:
            #{Regexp.escape(FILTERED)} | "(?:[^"\\]|\\.)*" | '(?:[^'\\]|\\.)*' |
            (?:(?:bearer|basic)\s+)? ["']? [^\s&;,"'<>)]+
          )
        /ix
        @mask_fields_pattern = [fields, pattern]
        return pattern
      end
    end
  end
end
