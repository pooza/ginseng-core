# ginseng-core

pooza の自作アプリケーション群が共通で使う土台のライブラリです。
設定の読み込み・ログ（資格情報のマスク込み）・HTTP クライアント（リトライ・リダイレクトと宛先の検証込み）・常駐プロセス・外部コマンドの実行などを持ちます。

Fediverse・Web・Redis・PostgreSQL などは、この gem の上に作った別の gem（`ginseng-fediverse` ほか）にあります。

## このリポジトリについて

pooza の自作アプリケーション群のための内部ライブラリです。
MIT ライセンスで公開していますが、GitHub に置いている以上の配布（rubygems.org への公開など）は予定していません。

- 互換性は利用側のアプリの都合で変え、破壊的な変更も major を上げて行います
- 外部での利用を想定したサポートや問い合わせへの対応は行いません
- Issue・PR は受け付けますが、取り込むか・いつ返答するかはお約束できません

## 導入

rubygems.org には無いので、`Gemfile` で GitHub のタグを指定して参照します。
最新のタグは [Releases](https://github.com/pooza/ginseng-core/releases) を見てください。

```ruby
gem 'ginseng-core', github: 'pooza/ginseng-core', tag: 'vX.Y.Z', require: 'ginseng'
```

Ruby 3.3 以上が必要です。

## 使い方

アプリ側でモジュールを 1 つ作り、`Ginseng::Package` を include して、必要なクラスを継承して差し替えます。
`*_class` を上書きすると、gem の内部もアプリのクラスを使うようになります。

```ruby
module MyApp
  module Package
    include Ginseng::Package

    def environment_class
      return Environment
    end

    def config_class
      return Config
    end

    def self.name
      return 'my-app'
    end
  end

  class Environment < Ginseng::Environment
    include Package

    def self.dir
      return File.expand_path('../..', __dir__)
    end
  end

  class Config < Ginseng::Config
    include Package
  end
end
```

配っている rake タスク（`cert:update` / `cert:check`）は、アプリの `Rakefile` から読みます。
⚠ 自分の `Environment` を渡してください。省略すると gem 自身のディレクトリへ書き込みます。

```ruby
Ginseng.load_tasks(environment: MyApp::Environment)
```

## 主なクラス

| クラス | 役割 |
| --- | --- |
| `Ginseng::Package` | アプリが include する入口。どのクラスを使うか（`*_class`）と、名前・版・User-Agent |
| `Ginseng::Environment` | 実行環境（ディレクトリ・ホスト名・development / production・プラットフォーム・証明書） |
| `Ginseng::Config` | YAML の設定。`config/` → `/usr/local/etc/<name>` → `/etc/<name>` を探し、`<hostname>` > `local` > `application` > `lib` の順に優先する。`config['/a/b']` で読む。JSON Schema での検証 |
| `Ginseng::Logger` | JSON 形式のログ。資格情報は `Ginseng::Masking` で伏せてから書く |
| `Ginseng::Masking` | ログ・外部送信の直前に、パスワードやトークン、URL 中の資格情報を伏せる |
| `Ginseng::HTTP` | HTTParty の上に作った HTTP クライアント。リトライ、リダイレクトを 1 段ずつ追う、宛先の検証（`host_validator`）、応答の大きさの上限 |
| `Ginseng::PublicHost` | 公開アドレスだけを通す `host_validator`。外部が決めた URL を取りに行くとき用 |
| `Ginseng::Daemon` | 常駐プロセスの起動・停止・pid ファイルの管理 |
| `Ginseng::CommandLine` | 外部コマンドの実行。締め切り・引数中の資格情報の伏せ字 |
| `Ginseng::Template` | テンプレートの描画 |
| `Ginseng::Mailer` / `Ginseng::Slack` / `Ginseng::LineService` | 通知の送り先 |
| `Ginseng::Crypt` | 設定値などの暗号化・復号 |
| `Ginseng::URI` | `Addressable::URI` の拡張 |
| `Ginseng::Error` とサブクラス | HTTP のステータスと対応づけた例外（`GatewayError` / `NotFoundError` / `AuthError` など） |
| `Ginseng::TestCase` | アプリのテストの基底クラス |

詳しい振る舞いはソースのコメントにあります。

## ライセンス

[MIT](LICENSE.txt)
