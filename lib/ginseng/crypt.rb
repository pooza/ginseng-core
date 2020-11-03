require 'openssl'
require 'base64'

module Ginseng
  class Crypt
    include Package
    GLUE = '::::'.freeze

    def initialize
      @config = config_class.instance
      @logger = logger_class.new
    end

    def encrypt(plaintext, bit = 256)
      salt = create_salt
      enc = OpenSSL::Cipher.new("AES-#{bit}-CBC")
      enc.encrypt
      keyiv = create_key_iv(password, salt, enc)
      enc.key = keyiv[:key]
      enc.iv = keyiv[:iv]
      encrypted = enc.update(plaintext) + enc.final
      return [encode(encrypted), encode(salt)].join(GLUE)
    rescue => e
      raise AuthError, e.message, e.backtrace
    end

    def decrypt(joined, bit = 256)
      encrypted, salt = joined.split(GLUE).map {|v| decode(v)}
      dec = OpenSSL::Cipher.new("AES-#{bit}-CBC")
      dec.decrypt
      keyiv = create_key_iv(password, salt, dec)
      dec.key = keyiv[:key]
      dec.iv = keyiv[:iv]
      return dec.update(encrypted) + dec.final
    rescue => e
      raise AuthError, e.message, e.backtrace
    end

    private

    def create_salt
      return OpenSSL::Random.random_bytes(8)
    end

    def create_key_iv(password, salt, aes)
      keyiv = OpenSSL::PKCS5.pbkdf2_hmac(
        password,
        salt,
        2000,
        aes.key_len + aes.iv_len,
        'sha256',
      )
      return {
        key: keyiv[0, aes.key_len],
        iv: keyiv[aes.key_len, aes.iv_len],
      }
    end

    def encode(string)
      case encoder
      when 'base64'
        return Base64.strict_encode64(string).chomp
      when 'hex'
        return string.bin2hex
      else
        raise "Invalid encoder '#{encoder}'"
      end
    end

    def decode(string)
      case encoder
      when 'base64'
        return Base64.strict_decode64(string)
      when 'hex'
        return string.hex2bin
      else
        raise "Invalid encoder '#{encoder}'"
      end
    end

    def encoder
      return @config['/crypt/encoder']
    end

    def password
      return @config['/crypt/password']
    end
  end
end
