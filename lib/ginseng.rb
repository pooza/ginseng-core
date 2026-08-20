# frozen_string_literal: true

require 'bundler/setup'
require 'ginseng/refines'
require 'active_support'
require 'active_support/core_ext'
require 'zeitwerk'
require 'yaml'
require 'yajl'
require 'yajl/json_gem'
require 'json-schema'
require 'addressable/uri'

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym 'API'
  inflect.acronym 'CI'
  inflect.acronym 'DSN'
  inflect.acronym 'HTTP'
  inflect.acronym 'MIME'
  inflect.acronym 'OAuth'
  inflect.acronym 'RSS'
  inflect.acronym 'SNS'
  inflect.acronym 'UI'
  inflect.acronym 'URI'
  inflect.acronym 'URL'
end

module Ginseng
  using Refines

  def self.dir
    return File.expand_path('..', __dir__)
  end

  # gem が配る rake タスクを読む。⚠ **利用アプリの Rakefile から呼ぶ入り口**
  # (#512)。`cert:update` / `cert:check` を 3 つのアプリに 3 回書かないため。
  #
  # ⚠⚠ **自分の Environment を渡すこと (#548)。** 省略すると `Ginseng::Environment`
  # ＝ **gem のルート**が使われ、`cert:update` が**依存の中身へ書き込む**（読み取り
  # 専用なら失敗する）。アプリの `cert/cacert.pem` は相変わらず作られない。
  #
  # ```ruby
  # require 'makoto'
  # Ginseng.load_tasks(environment: Makoto::Environment)
  # ```
  def self.load_tasks(environment: Environment)
    @task_environment = environment
    Dir.glob(File.join(__dir__, 'tasks/*.rake')).each {|f| load(f)}
  end

  # 配った rake タスクが見る Environment。
  def self.task_environment
    return @task_environment ||= Environment
  end

  # ⚠ **この gem が `SSL_CERT_FILE` に立てた値 (#556)。** 運用者が渡した値と
  # 区別するために覚えておく。立てていなければ nil。
  class << self
    attr_accessor :managed_cert_file
  end

  # ⚠⚠ **CA バンドルの取得だけは OS の CA ストアで検証する (#554)。**
  #
  # `cert:update` / `cert_fresh?` は `/cert/url` を取りに行くが、`HTTP#initialize`
  # は（在れば）自分の `cacert.pem` を `SSL_CERT_FILE` に立てる。⚠ つまり
  # **これから置き換えようとしている当のバンドルで取得先の TLS を検証**していた。
  # そのバンドルが古くて取得先を検証できなくなった瞬間、**更新も鮮度確認もできなく
  # なる**（鶏と卵。#515 の「当番が居ない」と組み合わさると静かに詰む）。
  #
  # ⚠ **HTTP のインスタンスを作ってから呼ぶこと。** `initialize` が env を立てる
  # ので、ブロックの中で `HTTP.new` すると外した意味が無くなる。
  #
  # ⚠ `ENV` はプロセス全体で共有なので、**取得のあいだだけ**外して必ず戻す。
  #
  # 🔴 **外すのは自分で立てた値だけ (#556)。** 運用者が `SSL_CERT_FILE` で企業内 CA や
  # プラットフォームのトラストストアを渡している環境があり、**無条件に外すと
  # `cert:update` / `cert:check` が TLS ごと失敗する**。外したかったのは「これから
  # 置き換える対象のバンドル」だけ。
  def self.with_system_cert_store
    return yield unless ENV.fetch('SSL_CERT_FILE', nil) == managed_cert_file
    original = ENV.delete('SSL_CERT_FILE')
    return yield
  ensure
    ENV['SSL_CERT_FILE'] = original if original
  end

  def self.loader
    config = YAML.load_file(File.join(dir, 'config/autoload.yaml'))
    loader = Zeitwerk::Loader.new
    loader.inflector.inflect(config['inflections'])
    config['entries'].each do |entry|
      loader.push_dir(File.join(dir, entry['path']), namespace: entry['namespace'].constantize)
    end
    return loader
  end

  # json-schema の `uri` は Addressable でパースできるかしか見ない (JSON::Schema::UriFormat)
  # ため、`これはURLではない` や `precure.ml` のような相対参照も「妥当な URI」として通る。
  # 弾けるのは `::::` のような構文破綻だけで、format: uri は事実上何も検証していない。
  #
  # ⚠ `validate_formats: true` を渡しても変わらない。json-schema 6 は format を既定で
  # 検証しており、緩いのはフラグではなく uri の検証内容そのもの。フラグの問題だと
  # 読むと「立てたのに直らない」で終わる。
  #
  # RFC 3986 / JSON Schema の uri は絶対 URI（スキーム必須）を指し、相対を許すのは
  # uri-reference の側なので、スキームを要求するのは仕様への追従であって独自拡張ではない。
  # 書いてあるのに何も弾かない指定は「守っているつもりで無防備」で、利用アプリ 2 つで
  # 実際に穴になっていた (pooza/makoto2#35 / pooza/tomato-shrieker#1461)。
  #
  # ⚠⚠ スキームを http(s) には限定しない。postgres:// / redis:// も妥当な URI で、
  # モロヘイヤが dsn に format: uri を使っている。「http でなければならない」はアプリ側の
  # 要件なので、schema の pattern で書く。したがって `htps://example.com` のような
  # スキーム名の typo はここでは止まらない。
  #
  # 非文字列は素通しする。型の誤りは type が報告する担当で、ここで二重に鳴らすと
  # 1 つの誤りが 2 行のエラーになる。
  def self.setup_json_schema
    JSON::Validator.register_format_validator('uri', proc {|value|
      next unless value.is_a?(String)
      uri = begin
        Addressable::URI.parse(value)
      rescue Addressable::URI::InvalidURIError
        nil
      end
      next if uri&.absolute?
      raise JSON::Schema::CustomFormatError, 'must be an absolute URI (scheme required)'
    })
  end

  # ⚠ ricecream は gemspec の依存ではない。アプリが Gemfile に書かなければ存在せず、
  # `--without development` で入れたバンドルでも消える。ここで LoadError を拾わないと
  # **`require 'ginseng'` そのものが落ち、アプリが起動できなくなる**。
  # デバッグ支援が無いだけなので、黙って諦めてよい。
  def self.setup_debug
    require 'ricecream'
    Ricecream.disable
    return unless Environment.development?
    Ricecream.enable
    Ricecream.include_context = true
    Ricecream.colorize = true
    Ricecream.prefix = "#{Package.name} | "
    Ricecream.define_singleton_method(:arg_to_s, proc {|v| PP.pp(v)})
  rescue LoadError
    nil
  end

  Bundler.require
  loader.setup
  setup_json_schema
  setup_debug
end
