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
end
