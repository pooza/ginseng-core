# frozen_string_literal: true

# CA 証明書（curl 配布のバンドル）の取得と鮮度確認。
#
# ⚠⚠ **利用アプリからも使えるように gem 側へ置く (#512)。**この gem の Rakefile
# にしか無かったため、`cert:update` を持たないアプリでは `cert/cacert.pem` が
# **一度も作られなかった**。⚠ **3 つのアプリに同じタスクを 3 回書かない。**
#
# 利用アプリの Rakefile で:
#
# ```ruby
# require 'makoto'
# Ginseng.load_tasks(environment: Makoto::Environment)
# ```
#
# ⚠⚠ **`Ginseng::Environment` を直に見ないこと (#548)。** それは **gem のルート**を
# 指すので、`cert:update` が**依存の中身（bundler のチェックアウト）へ書き込む**。
# 読み取り専用なら失敗し、書けてもアプリの `cert/` は空のまま。
#
# ⚠ `zeitwerk` の管理下（`lib/ginseng` 以下）には置かない。`.rake` は
# autoload の対象外なので、置き場所を分けて意図を明示する。
namespace :cert do
  desc 'update cert'
  task :update do
    file = Ginseng.task_environment.cert_file
    puts "fetch #{file}"
    # ⚠ 利用アプリには cert/ ディレクトリそのものが無い。
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, Ginseng::HTTP.new.get(Ginseng::Config.instance['/cert/url']).body)
  end

  desc 'check cert'
  task :check do
    environment = Ginseng.task_environment
    unless environment.cert_fresh?
      warn "'#{environment.cert_file}' is not fresh."
      exit 1
    end
  end
end
