module Ginseng
  module Refines
    class ::Integer
      def commaize
        return to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\1,')
      end
    end

    class ::String
      def ellipsize(length)
        i = 0
        str = ''
        each_char do |c|
          i += c.length
          if length < i
            str += '…'
            break
          end
          str += c
        end
        return str
      end

      def ellipsize!(length)
        replace(ellipsize(length))
        return self
      end

      def nfkc
        require 'unicode'
        return Unicode.nfkc(self)
      end

      def nfkc!
        replace(nfkc)
        return self
      end

      def sanitize
        require 'sanitize'
        require 'nokogiri'
        return Nokogiri::HTML.parse(
          Sanitize.clean(self),
        ).text
      end

      def sanitize!
        replace(sanitize)
        return self
      end

      def adler32
        require 'zlib'
        return Zlib.adler32(self)
      end

      def hex2bin
        s = self
        raise 'Not a valid hex string' unless /^[\da-fA-F]+$/.match?(s)
        s = "0#{s}" unless (s.length & 1).zero?
        return s.scan(/../).map {|b| b.to_i(16)}.pack('C*').force_encoding('UTF-8')
      end

      def bin2hex
        return unpack('C*').map {|b| '%02x' % b}.join
      end
    end

    class ::Array
      def deep_compact
        return clone.deep_compact!
      end

      def deep_compact!
        each do |value|
          next unless value.class.method_defined?(:deep_compact!)
          value.deep_compact!
          delete(value) if value.empty?
        end
        compact!
        return self
      end
    end

    class ::Hash
      def deep_merge(target)
        return Hash.deep_merge(self, target)
      end

      def deep_merge!(target)
        replace(deep_merge(target))
        return self
      end

      def key_flatten(prefix = '')
        return Hash.key_flatten(prefix, self)
      end

      def key_flatten!(prefix = '')
        replace(key_flatten(prefix))
        return self
      end

      def deep_compact
        return clone.deep_compact!
      end

      def deep_compact!
        each do |key, value|
          next unless value.class.method_defined?(:deep_compact!)
          value.deep_compact!
          delete(key) if value.empty?
        end
        compact!
        return self
      end

      def self.deep_merge(src, target)
        raise ArgumentError 'Not Hash' unless target.is_a?(Hash)
        dest = src.clone || {}
        target.each do |k, v|
          dest[k] = v.is_a?(Hash) ? deep_merge(dest[k], v) : v
        end
        return dest.compact
      end

      def self.key_flatten(prefix, node)
        values = {}
        if node.is_a?(Hash)
          node.each do |key, value|
            values.update(key_flatten("#{prefix}/#{key}", value))
          end
        else
          values[prefix.downcase] = node
        end
        return values
      end
    end

    class ::NilClass
      def empty?
        return true
      end
    end

    module ::Process
      def self.alive?(pid)
        kill(0, pid)
        return true
      rescue
        return false
      end
    end
  end
end
