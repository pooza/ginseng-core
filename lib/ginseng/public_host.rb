# frozen_string_literal: true

require 'ipaddr'
require 'resolv'
require 'timeout'

module Ginseng
  # 外部が決めた URL を取りにいくときの、**公開アドレスだけを通す** host_validator (#660)。
  #
  # ⚠⚠ **受け口（`HTTP` の `host_validator`）と同じ gem に、既製品を 1 つ置く。**
  # 🔴 無かった間、同じ判定が `mulukhiya-toot-proxy`（`Mulukhiya::RemoteHost`）と
  # `ginseng-web`（`Ginseng::Web::PublicHost`）に**写しとして**在った。予約レンジの表は
  # 足されていく種類のもので、**写しは必ずずれる** — 実際、`fec0::/10` と名前解決全体の
  # 締め切りは ginseng-web の側にしか入っていなかった。
  #
  # ⚠ 使い方: `http.get(url, {host_validator: Ginseng::PublicHost.validator})`
  module PublicHost
    IPV4_LITERAL = /\A\d{1,3}(\.\d{1,3}){3}\z/

    # ⚠ 名前解決 1 回ぶん（ホスト 1 つ）の待ちの上限（秒）。⚠⚠ 締め切りが無いと、応答を
    # 引き延ばす権威 DNS を立てられるだけで、呼び出し側のスレッドを占有される。
    DNS_TIMEOUT = 3

    # 名前解決の失敗（環境要因）。⚠ fail-closed で拒否に倒す。
    # ⚠ `Timeout::Error` は `resolve_addresses` の締め切り。
    # ⚠ `SystemCallError` は `Errno::*` の親（実測で `EACCES` / `EMFILE` が素のまま
    # 呼び出し側へ漏れていた）。
    # ⚠⚠ **`IPAddr::Error` は握らない。** 既定の resolver は IP アドレスしか返さないので、
    # ここで上がるのは差し替えた resolver の不具合 — 握ると「拒否」に化けて見えなくなる。
    RESOLUTION_ERRORS = [SocketError, Resolv::ResolvError, Timeout::Error, SystemCallError].freeze

    # ホスト名として受け付ける形（punycode へ直したあと）。
    # ⚠ `:` `[` `%` 空白などを含むものは、名前解決へ進めずに拒否する。
    HOSTNAME = /\A[a-z0-9_-]{1,63}(\.[a-z0-9_-]{1,63})+\.?\z/i

    # 🔴 **最後のラベルが数字（または `0x`）で始まる名前は、IPv4 の別表記として読まれうる。**
    # `127.1` `0x7f.1` `0177.0.0.1` は 4 オクテットの形ではないが、`getaddrinfo` は
    # `127.0.0.1` と読む。⚠ 実在の TLD に数字で始まるものは無い。
    NUMERIC_LAST_LABEL = /(?:\A|\.)(?:\d|0x)[^.]*\.?\z/i

    # ⚠ 名前の全長の上限（RFC 1035）。
    MAX_HOSTNAME_LENGTH = 253

    # `IPAddr` の `private?` / `loopback?` / `link_local?` が拾わない予約・特殊用途レンジ。
    # ⚠ **`0.0.0.0` と `::` は 3 述語のいずれも false** なのに、connect(2) はローカルホスト宛と
    # して扱う。
    #
    # ⚠⚠ **基準は IANA の Special-Purpose Address Registry で「グローバルに到達できない」
    # とされるもの (#660 Codex P1)。** 🔴 写し元の 2 つは一部しか持っておらず、文書用の
    # レンジ（`192.0.2.0/24` ほか）が**公開アドレスとして通っていた** — 名目上は予約でも、
    # 組織の中で経路を持たせている網がある。
    # 🔴🔴 **IPv4 を埋め込む IPv6 も落とす。** `2002:7f00:1::1`（6to4）は `127.0.0.1` を、
    # Teredo（`2001::/32`）は任意の IPv4 を指せるので、**表を IPv4 側だけ埋めても抜ける**
    # （実測で通っていた）。⚠ NAT64 も同じ理由で落とす（表ではなく `GLOBAL_UNICAST_V6` の外）。
    # ⚠ AS112（`192.31.196.0/24` / `192.175.48.0/24`）と AMT（`192.52.193.0/24`）は
    # グローバルに到達できる扱いなので入れない。
    # ⚠⚠ **逆向きには広めに落としている（意図どおり）。** 親ブロックの中で個別に
    # 「到達できる」とされた割り当て（`192.0.0.9` / `192.0.0.10`、`2001:1::1`〜`3`、
    # `2001:3::/32`、`2001:4:112::/48` ほか）は、親ごと落ちる。🔴 どれも基盤用の anycast
    # （PCP / TURN / AMT / AS112）で、**HTTP で取りにいく先にならない**。例外を刻むと
    # 「通す側の一覧」をもう 1 つ持つことになり、間違えたときに開くのは SSRF の側。
    # ⚠ **IPv6 は `GLOBAL_UNICAST_V6` の外を丸ごと落とす**ので、ここに並べるのは
    # その中にある例外だけ。
    RESERVED_RANGES = [
      '0.0.0.0/8',       # this-network
      '100.64.0.0/10',   # CGNAT (RFC 6598)
      '192.0.0.0/24',    # IETF protocol assignments
      '192.0.2.0/24',    # 文書用 TEST-NET-1
      '192.88.99.0/24',  # 6to4 relay anycast（廃止）
      '198.18.0.0/15',   # benchmarking (RFC 2544)
      '198.51.100.0/24', # 文書用 TEST-NET-2
      '203.0.113.0/24',  # 文書用 TEST-NET-3
      '224.0.0.0/4',     # multicast
      '240.0.0.0/4',     # reserved（255.255.255.255 を含む）
      '2001::/23',       # IETF protocol assignments（Teredo / ORCHID / benchmarking を含む）
      '2001:db8::/32',   # 文書用
      '2002::/16',       # 6to4（IPv4 を埋め込む）
      '3fff::/20',       # 文書用 (RFC 9637)
    ].map {|v| IPAddr.new(v)}.freeze

    # 🔴🔴 **IPv6 は「落とすもの」を並べず、通す範囲を 1 つ決める (#660 Codex P1・2 巡目)。**
    # ⚠⚠ グローバルに経路を持つ IPv6 ユニキャストは、いまのところ全部 `2000::/3` の中に
    # ある。🔴 外側には予約が点在していて（`::/128`・NAT64 の `64:ff9b::/96`・破棄用の
    # `100::/64`・ダミーの `100:0:0:1::/64`・SRv6 の `5f00::/16`・site-local の
    # `fec0::/10`・multicast …）、**並べる形は足すたびに 1 つ漏れる**（実際に 2 巡続けて
    # 漏れた）。⚠ IANA が外側へ新しい予約を足しても、ここは変えなくてよい。
    # ⚠ IPv4-mapped / -compatible は、判定の前に IPv4 へ畳んである。
    GLOBAL_UNICAST_V6 = IPAddr.new('2000::/3').freeze

    # `Ginseng::HTTP#get` の `host_validator` へ渡す callable。リダイレクトの各ホップがこれを通る。
    # ⚠ **真偽値ではなく IP アドレスを返す**（拒否なら nil）。`HTTP` は文字列が返ると
    # その IP アドレスへ接続を固定する — 名前で検証して名前で接続すると DNS リバインディングで抜けられる。
    def self.validator
      return ->(host) {allowed_address(host)}
    end

    # 許可できるなら接続に使う IP アドレスを、拒否なら nil を返す。
    #
    # ⚠ **IP アドレスのリテラルと、ドットを含まない名前は拒否する**（`localhost` や社内の
    # 短い名前）。
    # ⚠⚠ **1 本でも内部アドレスを含めば拒否する。** 公開のほうを選べばよい、ではない —
    # 混ぜて返してくるのはリバインディングそのもの。
    def self.allowed_address(host, resolver: method(:resolve_addresses))
      host = normalize(host)
      return nil unless host
      addrs = resolver.call(host)
      return nil if addrs.empty?
      return nil if addrs.any? {|ip| internal_address?(ip)}
      # ⚠ IPv4 があれば IPv4 を採る（A と AAAA が混ざって返る）。
      return addrs.find {|ip| IPV4_LITERAL.match?(ip)} || addrs.first
    rescue *RESOLUTION_ERRORS
      return nil
    end

    # 名前解決へ渡してよい形に直す。渡せなければ nil。
    #
    # 🔴 **国際化ドメイン名は punycode へ直す。** `HTTP` が validator へ渡すのは
    # 正規化前のホスト（`日本語.jp`）で、`Resolv` はそれを `Encoding::CompatibilityError`
    # で落とす — `GatewayError` にならずに呼び出し側へ漏れていた（実測）。⚠ 接続のほうは
    # punycode で行われるので、ここで直さないと**この validator を挿したときだけ取れない**。
    # ⚠ 形の壊れた名前をここで落とすのは、解決に進むと締め切りまで待つため。
    def self.normalize(host)
      host = Addressable::IDNA.to_ascii(host.to_s)
      return nil if host.length > MAX_HOSTNAME_LENGTH
      return nil unless HOSTNAME.match?(host)
      return nil if NUMERIC_LAST_LABEL.match?(host)
      return host
    rescue StandardError
      return nil
    end

    # 公開アドレスだけに解決されるか。⚠ 真偽だけが要るとき用（接続先は固定されない）。
    def self.public?(host, resolver: method(:resolve_addresses))
      return !allowed_address(host, resolver:).nil?
    end

    def self.internal_address?(ip)
      addr = IPAddr.new(ip)
      # ⚠ IPv4-mapped は素の IPv4 へ畳んでから突き合わせる（畳まないと
      # `::ffff:127.0.0.1` が family 違いで素通りする）。
      # ⚠ IPv4-compatible（`::a.b.c.d`）は畳まない — `GLOBAL_UNICAST_V6` の外として落ちる。
      # `IPAddr#ipv4_compat?` は obsolete で、警告が出る。
      addr = addr.native if addr.ipv4_mapped?
      return true if addr.private? || addr.loopback? || addr.link_local?
      return true if addr.ipv6? && !GLOBAL_UNICAST_V6.include?(addr)
      return RESERVED_RANGES.any? {|range| range.include?(addr)}
    end

    # ⚠ 解決できなければ空配列か例外になり、`allowed_address` は拒否に倒れる。
    #
    # 🔴🔴 **`Resolv::DNS#timeouts=` は問い合わせ 1 回ぶんの上限でしかない (pooza/ginseng-web#140 Codex P1)。**
    # `getaddresses` は A と AAAA を別々に引き、それぞれ**ネームサーバーを 1 台ずつ**待つので、
    # 応答しない相手には「種別 × ネームサーバー数 × timeout」かかる（実測: 1 秒・3 台で 6 秒）。
    # ⚠ **全体に 1 本の締め切りを掛ける。** `nameserver:` はテストで応答しない先を指すためのもの。
    # 🔴🔴 **例外クラスを渡さない。** `Resolv::ResolvTimeout` を渡すと、`Resolv` 自身が
    # 「問い合わせ 1 回のタイムアウト」として握って次のネームサーバーへ進むので、
    # **締め切りが効かない**（実測: 掛けたつもりで 18 秒）。既定の形なら中では握れない。
    # ⚠ `timeout:` は利用側が設定から渡すためのもの（`mulukhiya-toot-proxy` は
    # `/remote_host/dns/timeout` を持つ）。🔴 **`nil` を既定に読み替える** — 設定の
    # キーが欠けて `nil` が来ると、`Timeout.timeout(nil)` は**締め切りなし**になる（実測）。
    def self.resolve_addresses(host, nameserver: nil, timeout: DNS_TIMEOUT)
      timeout ||= DNS_TIMEOUT
      return Timeout.timeout(timeout) do
        resolver = nameserver ? Resolv::DNS.new(nameserver:) : Resolv::DNS.new
        resolver.timeouts = timeout
        resolver.getaddresses(host).map(&:to_s)
      ensure
        resolver&.close
      end
    end
  end
end
