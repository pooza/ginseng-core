module Ginseng
  class CryptTest < TestCase
    def setup
      @crypt = Crypt.new
      @config = Config.instance
      @config['/crypt/encoder'] = 'base64'
      @base64_encrypted = @crypt.encrypt('hogehoge')
      @config['/crypt/encoder'] = 'hex'
      @hex_encrypted = @crypt.encrypt('fugafuga')
    end

    def test_base64
      @config['/crypt/encoder'] = 'base64'
      assert_equal('hogehoge', @crypt.decrypt(@base64_encrypted))
      assert_equal('fugafuga', @crypt.decrypt(@hex_encrypted))
    end

    def test_hex
      @config['/crypt/encoder'] = 'hex'
      assert_equal('hogehoge', @crypt.decrypt(@base64_encrypted))
      assert_equal('fugafuga', @crypt.decrypt(@hex_encrypted))
    end

    def test_invalid_encoder
      @config['/crypt/encoder'] = 'huga'
      assert_raise CryptError do
        @crypt.encrypt('fugafuga')
      end
      assert_equal('hogehoge', @crypt.decrypt(@base64_encrypted))
      assert_equal('fugafuga', @crypt.decrypt(@hex_encrypted))
    end
  end
end
