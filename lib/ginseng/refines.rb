# frozen_string_literal: true

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
        return unicode_normalize(:nfkc)
      end

      def nfkc!
        replace(nfkc)
        return self
      end

      def sanitize
        require 'sanitize'
        return Sanitize.clean(gsub(%r{<br */?>}, "\n")).nokogiri.text.strip
      end

      def sanitize!
        replace(sanitize)
        return self
      end

      def remove_escape_sequences
        return gsub(/\e\[[\d;]*m/, '')
      end

      def remove_escape_sequences!
        return gsub!(/\e\[[\d;]*m/, '')
      end

      def sha256
        require 'digest/sha2'
        return Digest::SHA256.hexdigest(self)
      end

      def adler32
        require 'zlib'
        return Zlib.adler32(self).to_s
      end

      def nokogiri
        require 'nokogiri'
        # dup 必須。force_encoding はレシーバを破壊するため、frozen な文字列
        # （Ruby 4 のリテラル等）では FrozenError になる。
        return Nokogiri::HTML.parse(dup.force_encoding('utf-8'), nil, 'utf-8')
      end

      def hex2bin
        s = self
        raise 'Not a valid hex string' unless /^[\da-fA-F]+$/.match?(s)
        s = "0#{s}" unless s.length.nobits?(1)
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

    class ::Time
      def today?
        return strftime('%Y/%m/%d') == Date.today.strftime('%Y/%m/%d')
      end
    end

    class ::NilClass
      def empty?
        return true
      end
    end

    class ::StandardError
      def status
        return 500
      end

      def broadcastable?
        return true
      end

      def to_h
        return {
          package: Package.name,
          class: self.class.name,
          message:,
        }
      end
    end

    module ::Process
      # プロセスの生死。:alive / :dead / :unknown を返す。
      #
      # ⚠ **真偽 2 値では足りない** (#510)。`Errno::ESRCH`（存在しない）と
      # `Errno::EPERM`（**存在するが触れない**＝別ユーザーのプロセス）は違うことを
      # 意味するので、後者を「死んでいる」に読み替えない。
      #
      # ⚠ **`EPERM` を :alive にも寄せない。** pid が再利用されて他人のプロセスに
      # なっている場合、それは「うちのデーモン」ではない。分からないことは
      # :unknown と答える。
      def self.alive_state(pid)
        kill(0, pid)
        return :alive
      rescue Errno::ESRCH
        return :dead
      rescue StandardError
        # `Errno::EPERM`（存在するが触れない）と、pid として解釈できない引数など。
        # ⚠ **どちらも「死んでいる」に倒さない。**例外を投げない契約は保つ
        # （既存の呼び出し側が rescue していないため）。
        return :unknown
      end

      # ⚠ **:unknown は false 側に落ちる。**「生きていると断定できるか」の述語なので
      # それでよいが、**「死んでいる」と読み替えないこと**。原因を出すなら
      # alive_state を見る (#510)。
      def self.alive?(pid)
        return alive_state(pid) == :alive
      end
    end
  end
end
