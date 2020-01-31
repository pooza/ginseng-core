# https://qiita.com/acairojuni/items/1055c2f27cbd99e67fc2
class Integer
  def commaize
    return to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\1,')
  end
end

class String
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

class Hash
  def deep_merge(target)
    raise ArgumentError 'Not Hash' unless target.is_a?(Hash)
    dest = clone || {}
    target.each do |k, v|
      dest[k] = v.is_a?(Hash) ? dest[k].deep_merge(v) : v
    end
    return dest.compact
  end

  def deep_merge!(target)
    replace(deep_merge(target))
    return self
  end
end
