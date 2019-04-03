# https://qiita.com/acairojuni/items/1055c2f27cbd99e67fc2
class Integer
  def commaize
    return to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\1,')
  end
end

class String
  def ellipsize!(length)
    replace(ellipsize(length))
    return self
  end

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
end
