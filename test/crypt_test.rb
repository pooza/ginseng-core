module Ginseng
  class CryptTest < Test::Unit::TestCase
    def setup
      @crypt = Crypt.new
    end

    def test_encrypt
      encrypted = @crypt.encrypt('hogehoge')
      decrypted = @crypt.decrypt(encrypted)
      assert_equal(decrypted, 'hogehoge')
    end
  end
end
