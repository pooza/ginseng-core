require 'addressable/uri'

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

    def self.normalize_component(component,
      character_class = CharacterClasses::RESERVED + CharacterClasses::UNRESERVED,
      leave_encoded = '')

      begin
        unencoded = unencode_component(
          component.to_s.force_encoding(Encoding::ASCII_8BIT),
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

    def self.scan(text)
      return text.scan(%r{https?://[^\s[:cntrl:]]+}).map {|link| URI.parse(link)}
    end
  end
end
