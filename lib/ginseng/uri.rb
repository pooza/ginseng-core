# frozen_string_literal: true

require 'addressable/uri'
require 'uri'

module Ginseng
  class URI < Addressable::URI
    def normalized_path
      @normalized_path ||= begin
        path = self.path.to_s
        path = path.sub(':', '%2F') if scheme.nil? && path =~ NORMPATH
        result = path.strip.split(SLASH, -1).map do |segment|
          URI.normalize_component(segment)
        end.join(SLASH)

        result = URI.normalize_path(result)
        if result.empty? && ['http', 'https', 'ftp', 'tftp'].include?(normalized_scheme)
          result = SLASH.dup
        end
        result
      end
      @normalized_path&.force_encoding(Encoding::UTF_8)
      return @normalized_path
    end

    def local?
      return true if host == 'localhost'
      return true if host == '127.0.0.1'
      return true if host == '::1'
      return false
    end

    def self.normalize_component(component,
      character_class = CharacterClasses::RESERVED + CharacterClasses::UNRESERVED,
      leave_encoded = '')
      begin
        unencoded = unencode_component(
          # dup 必須。to_s は String に対して self を返すため、frozen な文字列を
          # 渡されると force_encoding が FrozenError になり、下の rescue に飲まれて
          # 「Can't convert String into String.」という無関係な TypeError に化ける。
          component.to_s.dup.force_encoding(Encoding::ASCII_8BIT),
          String,
          leave_encoded,
        )
      rescue
        raise TypeError, "Can't convert #{component.class} into String."
      end
      unless [String, Regexp].include?(character_class.class)
        raise TypeError, "Expected String or Regexp, got #{character_class.inspect}"
      end

      begin
        encoded = encode_component(unencoded, character_class, leave_encoded)
      rescue ArgumentError
        encoded = encode_component(unencoded)
      end
      return encoded.force_encoding(Encoding::UTF_8)
    end

    # URL の終わりとみなす全角の句読点と括弧 (#721)。日本語の文では URL の直後に空白が無いので、
    # 空白までを拾うと `https://example.com/a。次の文` が 1 つの URL になっていた。
    # ⚠ **非 ASCII 全体では切らない。** パスやクエリに生の日本語を含む URL を拾えなくなる。
    # ⚠ 代わりに、パスやクエリに生の全角の句読点・括弧を含む URL はそこで切れる
    # （`?q=「語」` は `?q=` まで）。括弧の対応は見ていない。
    # ⚠ 半角の末尾（`.` `,` `)`）は扱いを変えていない。
    SCAN_TERMINATORS = '。、，．！？：；（）「」『』【】〔〕〈〉《》［］｛｝｡､｢｣'
    private_constant :SCAN_TERMINATORS

    def self.scan(text)
      return enum_for(__method__, text) unless block_given?
      return text.clone.scan(scan_pattern(text.encoding)) do |link|
        yield URI.parse(link.gsub(/[[:cntrl:]]/, ''))
      end
    end

    # 🔴 **終端の文字は、本文の符号化に合わせて組む (#721)。** UTF-8 の正規表現のままだと
    # BINARY / Shift_JIS の本文で `Encoding::CompatibilityError` になる（それまでは拾えていた）。
    # ⚠ BINARY は UTF-8 のバイト列を先読みで止める。UTF-8 は自己同期なので、文字の途中では一致しない。
    # ⚠ 先読みは 1 文字ごとに全候補を試すので数倍遅い。文字の符号化では文字クラスにする。
    # ⚠ ASCII 互換でない符号化（UTF-16 など）は従来どおりの形のまま。
    def self.scan_pattern(encoding)
      return %r{https?://[[:^space:]]+} unless encoding.ascii_compatible?
      @scan_patterns ||= {}
      return @scan_patterns[encoding] ||= begin
        terminators = SCAN_TERMINATORS.chars.filter_map do |char|
          next char.b if encoding == Encoding::BINARY
          next char.encode(encoding)
        rescue EncodingError
          next nil
        end
        escaped = terminators.map {|v| Regexp.escape(v)}
        if encoding == Encoding::BINARY
          source = "https?://(?:(?!#{escaped.join('|'.b)})[[:^space:]])+".b
        else
          source = 'https?://[^[:space:]'.encode(encoding) << escaped.join << ']+'
        end
        Regexp.new(source)
      end
    end
    private_class_method :scan_pattern

    def self.decode(text)
      return ::URI.decode_www_form_component(text)
    end

    def self.fix(root, href)
      uri = URI.parse(href.to_s)
      return uri if uri.absolute?
      uri = URI.parse(root.to_s)
      return uri if href.to_s.empty?
      if href.to_s.start_with?('/')
        uri.path = href.to_s
      else
        uri.path = File.join('/', uri.path, href.to_s)
      end
      return uri
    end
  end
end
