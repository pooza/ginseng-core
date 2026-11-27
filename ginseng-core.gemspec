# frozen_string_literal: true

require 'yaml'
package = YAML.load_file(File.join(__dir__, 'config/lib.yaml'))['package']

Gem::Specification.new do |spec|
  spec.name = 'ginseng-core'
  spec.version = package['version']
  spec.authors = package['authors']
  spec.email = package['email']
  spec.summary = package['description']
  spec.description = package['description']
  spec.homepage = package['url']
  spec.license = package['license']
  spec.metadata['homepage_uri'] = package['url']
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>=3.3', '<5.0'

  # ⚠⚠ **下限は「外さない。より高い修正版へ上げるだけ」** — pooza/ginseng-style の
  # docs/workflow.md「依存の制約に『なぜ』を書く」。⚠ **いま lock に入っている版は
  # 床の根拠にならない**（lock は作り直されるし、利用側の別の制約で古い版へ落ちうる）。

  # ⚠⚠ activesupport は系列ごとに修正版が分かれるので、`>=7.2.3.1` では 8.0.0〜8.0.4 と
  # 8.1.0〜8.1.2 が入る。⚠ **単一の下限で全系列を閉じるには最も高い修正版に
  # するほかなく、これは事実上「8.1 系列に固定する」判断**（利用側 5 本とも
  # 既に 8.1.3.1 で、実害は無いことを実測した）。
  # CVE-2023-38037, CVE-2026-33176, CVE-2026-33170, CVE-2026-33169
  spec.add_dependency 'activesupport', '>=8.1.2.1'
  # ⚠⚠ **2.10.0 を床にするのは CVE ではなく、ログの平文を塞ぐため (#774)。** 2.9 系は読めない URL
  # （`https://[SECRET]/x` など）を `create_uri` で通してしまい、`repeat` の中で stdlib が落ちて
  # 撃ち直すたびに、行の `url:` へ平文で出ていた。2.10.0 は入口で弾き、#770 が包む。
  # ⚠ CVE-2026-35611 の床（2.9.0）は 2.10.0 で満たす。
  spec.add_dependency 'addressable', '>=2.10.0' # CVE-2026-35611 / #774
  spec.add_dependency 'cgi', '>=0.4.2' # CVE-2025-27219, CVE-2025-27220
  spec.add_dependency 'csv'
  spec.add_dependency 'date', '>=3.2.1' # CVE-2021-41817
  # ⚠⚠ 修正版が 4 系列に分かれている（`<4.0.3.1` / `=4.0.4` / `>=5.0.0,<6.0.1.1` /
  # `>=6.0.2,<6.0.4`）。⚠ 低い系列の修正版を床にすると高い系列の未修正版が入る。
  spec.add_dependency 'erb', '>=6.0.4' # CVE-2026-41316
  spec.add_dependency 'etc'
  spec.add_dependency 'facets'
  # 🔴 **上限の由来が記録されていない (#615)。** 2022-12-30 の `322381f`（#420、
  # 件名 `fileutils 1.7` だけで本文なし）が `~>1.6.0` から移しただけで、
  # **事故なのか単に当時の版へ追随しただけなのかが分からない**。⚠⚠ **分から
  # ないまま外さない**（それが pooza/ginseng-web で起きたこと）。⚠ いま 1.8.0 が
  # 出ているが、この上限に阻まれている。
  spec.add_dependency 'fileutils', '~>1.7.0'
  spec.add_dependency 'find'
  # ⚠⚠ **0.25.1 は security の修正版 (#767)。** リダイレクト先が別オリジンなら、`headers:` /
  # `cookies:` / 前のホストの `Set-Cookie` を送らなくなった（jnunemaker/httparty#916）。
  # ⚠ この gem はホップを自前で追い資格情報を落としている（#655）ので振る舞いは変わらないが、
  # HTTParty を直接呼ぶ利用側に届かせるために上げる。⚠ 0.25.0 の破壊的変更（相対 `Location` の
  # 解決・空パスの扱い）は、自前で追う・`normalize` で `/` が付くため、この gem には当たらない（実測）。
  spec.add_dependency 'httparty', '>=0.25.1' # CVE-2025-68696 / #767
  spec.add_dependency 'json-schema'
  spec.add_dependency 'mail', '>=2.5.5' # CVE-2011-0739, CVE-2012-2139, CVE-2012-2140, CVE-2015-9097
  spec.add_dependency 'net-protocol'
  spec.add_dependency 'net-smtp'
  # ⚠ 1.19.4 の required_ruby_version は `>= 3.2` で、この gem の `>=3.3` より
  # 緩いので利用側を Ruby の版で押し出さない（実測）。
  # GHSA-c4rq-3m3g-8wgx ほか 10 件（1.19.1 / 1.19.3 / 1.19.4 で修正）
  spec.add_dependency 'nokogiri', '>=1.19.4'
  spec.add_dependency 'optparse'
  # ⚠ 下限は CVE-2020-8130、除外は 13.4.0 のみ lib/rake/options.rb 欠落の
  # アップストリームバグ（13.4.2 で修正済み）。**理由が別なので併記する。**
  spec.add_dependency 'rake', '>=12.3.3', '!= 13.4.0' # CVE-2020-8130
  # ⚠⚠ **`Ginseng::PublicHost` が、外部の決めた名前を `Resolv::DNS` で引く (#660)。**
  # 🔴 床が無いと Ruby 同梱の版（4.0 は 0.7.0・3.4 は 0.7.1）が読み込まれ、悪意のある
  # DNS 応答でメモリが増え続ける（実測: 300 回の解決で定数が 34 → 12034）。
  # ⚠ 0.7.2 の required_ruby_version は `>= 2.3.0` で、この gem の `>=3.3` を押し出さない。
  # ⚠ **外してよい条件**: 対応する Ruby がすべて 0.7.2 以上を同梱したとき。
  spec.add_dependency 'resolv', '>=0.7.2' # CVE-2026-80212, CVE-2026-80213
  spec.add_dependency 'sanitize', '>=6.0.2' # CVE-2023-36823
  spec.add_dependency 'securerandom'
  spec.add_dependency 'set'
  spec.add_dependency 'syslog'
  spec.add_dependency 'time', '>= 0.2.2' # CVE-2023-28756
  spec.add_dependency 'yajl-ruby', '>= 1.4.3' # CVE-2022-24795
  spec.add_dependency 'zeitwerk', '>=2.4.0'
  spec.add_dependency 'zlib', '>=3.2.3' # CVE-2026-27820
end
