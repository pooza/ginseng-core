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
        if result.empty? && ['http', 'https', 'ftp', 'tftp'].member?(normalized_scheme)
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
          component.to_s.force_encoding(Encoding::ASCII_8BIT),
          String,
          leave_encoded,
        )
      rescue
        raise TypeError, "Can't convert #{component.class} into String."
      end
      unless [String, Regexp].member?(character_class.class)
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
      return enum_for(__method__, text) unless block_given?
      return text.clone.scan(%r{https?://[[:^space:]]+}) do |link|
        yield URI.parse(link.gsub(/[[:cntrl:]]/, ''))
      end
    end

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
