# https://qiita.com/acairojuni/items/1055c2f27cbd99e67fc2
class Integer
  def commaize
    return to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\1,')
  end
end
