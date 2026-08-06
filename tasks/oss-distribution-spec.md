# CasRec OSS 配布 仕様書 — 無料構成（自己署名 + GitHub Releases）

作成: 2026-08-06 / 対象ブランチ: `claude/oss-distribution-methods-3df249`
この文書は実装エージェントへの**単一の真実**である。迷ったらこの文書の数値・コマンド・文言をそのまま使い、判断が必要になったら実装せずに報告する。

関連: [oss-distribution-tasks.md](oss-distribution-tasks.md)（タスク分割と委譲プロンプト） / [todo.md](todo.md) / [../README.md](../README.md) / [../Makefile](../Makefile)

---

## 0. これは何を変え、何を変えないか

**変えるもの**: ビルド成果物の署名オプション、バージョン注入、リリース成果物（zip + チェックサム）の生成手順、公開向けドキュメント。

**変えないもの**: `Sources/` 配下のコード、`Tests/` 配下のテスト、DESIGN.md の設計、CI の `test` ジョブ、`make build` / `make test` / `make run` の既存の使い勝手。

書き込みが許されるのは以下だけ:

```
Makefile
Resources/CasRec.entitlements   （新規）
README.md
RELEASING.md                    （新規）
.gitignore
```

**`Sources/` または `Tests/` を触る変更が必要になったら、実装せず報告する。**

---

## 1. 決定事項

| 論点 | 決定 | 理由 |
|------|------|------|
| Apple Developer Program（$99/年） | **当面入らない** | まず無料で公開して反応を見る。移行コストは小さい（§6） |
| 署名 | **自己署名証明書 `CasRec Release`**（有効期限 2036-08-02）。ad-hoc（`-`）にはしない | ad-hoc は cdhash が毎ビルド変わり、更新のたびに画面収録の許可が飛ぶ（lessons.md 2026-08-03 で実測済み） |
| 開発ビルドと配布ビルドの署名 | **同じ `CasRec Release` を使う**。`CasRec Dev`（2027-08-03 失効）は退役 | 識別子を1つに保てば DR も1つで済み、ローカルでの動作確認がそのまま配布物の検証になる。取り違え事故も起きない |
| Hardened Runtime | **いま有効にする**（`--options runtime`） | 有料へ移行する日に「マイクが動かない」を発見しないため。自己署名でも付けられることは実測済み（§2） |
| タイムスタンプ | **いま付ける**（`--timestamp`） | 証明書失効後も既存署名が有効なまま残る。自己署名でも Apple の TSA が受理することは実測済み（§2） |
| 署名の実行場所 | **ローカルのみ。秘密鍵を CI に置かない** | §1.1 |
| 配布物 | GitHub Releases に `CasRec-<version>.zip` + `checksums.txt` | notarization がない代わりにチェックサムで同一性を担保する |
| Homebrew Cask | **Phase B（今回のスコープ外）** | tap リポジトリの作成が別途必要。まず Releases を成立させる |
| 自動更新（Sparkle） | **やらない** | 未署名アプリの自動更新は信頼の観点で筋が悪い |

### 1.1 秘密鍵を CI に置かない理由

自己署名証明書には金銭的価値はないが、**画面収録アプリ固有のリスク**がある。同じ証明書・同じ bundle id で署名された別のアプリは、利用者が CasRec に与えた画面収録の TCC 許可を、ダイアログなしで引き継げる。鍵が漏れると「許可を求めてこない偽 CasRec」が作れてしまう。リリース頻度が月1回程度であれば CI 署名の利得は小さく、リスクに見合わない。

したがってリリース作業は**ローカルで `make release` → `gh release create` で成果物を添付**する。CI は既存のテストジョブのままとし、リリース用ワークフローは作らない。

---

## 2. 検証済みの事実（実装の前提）

すべて 2026-08-06 に実測。**推測ではない。**

| 事実 | 状態 | 根拠 |
|------|------|------|
| 自己署名の designated requirement は leaf hash 固定で、リビルドに耐える | VERIFIED | `codesign -d -r- CasRec.app` → `identifier "dev.toshi0607.casrec" and certificate leaf = H"…"` |
| 自己署名証明書でも `--timestamp` が通る（Apple TSA が受理） | VERIFIED | 実測: `Timestamp=Aug 6, 2026 at 1:02:54` |
| 自己署名証明書でも `--options runtime` が付く | VERIFIED | 実測: `flags=0x10000(runtime)` |
| ad-hoc 署名に `--timestamp` を渡してもエラーにならず、単に無視される | VERIFIED | 実測: exit 0、`Signature=adhoc`、Timestamp 行なし。**署名フラグを識別子ごとに分岐する必要はない** |
| **`CasRec Release`（10年）で `.app` を署名し、Hardened Runtime・タイムスタンプ・entitlements が同時に成立する** | VERIFIED | 実 `.app` に対し実測（2026-08-06）: `codesign --verify --deep --strict` 成功、`flags=0x10000(runtime)`、`Timestamp=Aug 6, 2026 at 1:02:54`、`com.apple.security.device.audio-input => true`、DR = `identifier "dev.toshi0607.casrec" and certificate leaf = H"4feed5cfc27c13bd9711823f1edd9a4ee2a96b44"` |
| 旧証明書 `CasRec Dev` の有効期限は 2027-08-03（退役対象） | VERIFIED | `openssl x509 -dates` → `notAfter=Aug 3 08:16:29 2027 GMT` |
| 現行 `Makefile` の codesign に `--options runtime` / `--timestamp` がない | VERIFIED | [Makefile:44](../Makefile) |
| `CFBundleShortVersionString` が `0.1.0` ベタ書き、`CFBundleVersion` が `2` ベタ書き | VERIFIED | `plutil -p Resources/Info.plist` |
| README は英語セクション + `## 日本語` セクションの二部構成 | VERIFIED | `grep '^#' README.md` |

### 2.1 期限切れ証明書の意味（重要）

タイムスタンプ付き署名は、証明書が期限切れになった後も有効なまま残る。**しかし期限切れの証明書で新しく署名することはできない。** 証明書を作り直すと leaf hash が変わり、**全利用者の画面収録許可が一斉に飛ぶ**。

旧 `CasRec Dev` は 2027-08-03 に切れるため、公開前に `CasRec Release`（2036-08-02 まで）へ移行した（§3 H1 完了）。**次に更新が必要になるのは 2036 年**であり、それまでこの問題は起きない。

2036 年に更新する際、または何らかの理由で証明書を作り直す際は、リリースノートで利用者に画面収録の再許可を案内すること。

---

## 3. 人間（toshi0607）にしかできない作業

| ID | 作業 | 状態 |
|----|------|------|
| **H1** | 有効期間 3650 日の自己署名コード署名証明書 `CasRec Release` を作成し、ログインキーチェーンへ登録する | **完了（2026-08-06）**。§3.1 参照 |
| **H2** | `CasRec Release` の秘密鍵を `.p12` で書き出し、リポジトリ外の安全な場所（パスワードマネージャ等）へバックアップする | **完了（2026-08-06、toshi0607 が実施）**。手順は §3.2 |
| **H3** | 署名した `.app` で、画面収録とマイク録音が実際に動くことを確認する（Hardened Runtime 有効化の実証。GUI と TCC が必要なため自動化不可） | **完了（2026-08-06、合格）**。ZIP 展開版で 38.2 秒録画、マイクトラックに 3,317,632 samples / mean -35.7 dB を確認。詳細は tasks/todo.md |
| **H4** | `gh release create` の実行（外部公開操作） | 未了。全タスク完了後 |

### 3.1 H1 の実施内容（完了記録）

Keychain Access の証明書アシスタントではなく、パラメータを明示できる CLI で作成した。

```
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=CasRec Release/C=JP" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -out tmp.p12 -inkey key.pem -in cert.pem -name "CasRec Release" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -passout pass:tmp

security import tmp.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P tmp -T /usr/bin/codesign
```

`-macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES` は必須。OpenSSL 3.x の既定の PBE / MAC アルゴリズムは macOS の `security import` が検証できず、`MAC verification failed` で失敗する（2026-08-06 に実測）。

結果:

| 項目 | 値 |
|------|-----|
| Common Name | `CasRec Release` |
| 有効期間 | 2026-08-05 〜 **2036-08-02** |
| SHA-1 fingerprint | `4F:EE:D5:CF:C2:7C:13:BD:97:11:82:3F:1E:DD:9A:4E:E2:A9:6B:44` |
| `EXPECTED_LEAF` 用の値 | `4feed5cfc27c13bd9711823f1edd9a4ee2a96b44` |

中間生成物（`key.pem` / `tmp.p12`）は検証後に削除済み。作成直後の秘密鍵はログインキーチェーンにのみ存在し単一障害点だったが、**H2 のバックアップ完了（2026-08-06）により解消済み**。

`security find-identity -v -p codesigning` にこの証明書は現れない（自己署名ルートは信頼されないため `CSSMERR_TP_NOT_TRUSTED` 扱いになる）が、**`codesign` は問題なく使える**。lessons.md 2026-08-03 の記録と同じ挙動である。

### 3.2 H2 の手順（toshi0607 が実施）

秘密鍵のバックアップは、パスワードを設定する操作を含むため本人が行う。

1. Keychain Access を開く（Spotlight に出ないため `open "/System/Library/CoreServices/Applications/Keychain Access.app"`）
2. 左サイドバーで **「ログイン」** キーチェーン → カテゴリ **「自分の証明書」** を選ぶ
3. `CasRec Release` を右クリック → **「"CasRec Release" を書き出す...」**
4. フォーマット: **個人情報交換 (.p12)** を選んで保存
5. 書き出し用パスワードを設定 → ログインパスワードを入力

**カテゴリは必ず「自分の証明書」から選ぶこと。** 「証明書」カテゴリから書き出すと秘密鍵を含まない `.cer` になり、バックアップの用をなさない。

保存先はリポジトリ外（1Password 等）。`.p12` をリポジトリに置いてはいけない。

---

## 4. 実装タスクの仕様

### T1 — Hardened Runtime と entitlements

**新規: `Resources/CasRec.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
```

含めるのはこの1つだけ。**App Sandbox（`com.apple.security.app-sandbox`）は入れない** — CasRec は sandbox 化されておらず、有効にすると ffmpeg 実行とライブラリの保存先が壊れる。画面収録に entitlement は不要（非 sandbox アプリでは TCC が担当する）。

**`Makefile` の codesign 行**を次のとおり変更する。

```make
CODESIGN_IDENTITY ?= CasRec Release
ENTITLEMENTS := Resources/CasRec.entitlements

# 期待する designated requirement の leaf hash。リリース署名の取り違えを防ぐ。
# 証明書を作り直したらこの値も更新する(tasks/oss-distribution-spec.md §2.1)。
EXPECTED_LEAF := 4feed5cfc27c13bd9711823f1edd9a4ee2a96b44
```

既定の識別子を `CasRec Dev` から **`CasRec Release` へ変更する**（§1 の決定）。既存のコメントブロックのうち「`CasRec Dev` は自己署名証明書である」旨の説明は、証明書名を `CasRec Release` に置き換えて残す。

**副作用**: 開発機の画面収録許可は DR が変わるため一度だけ失効する。lessons.md 2026-08-03 の手順どおり `tccutil reset ScreenCapture dev.toshi0607.casrec` で古いレコードを掃除してから再許可する。公開前の一度きりで、利用者には影響しない。

codesign の呼び出し:

```make
	codesign --force --options runtime --timestamp \
		--entitlements "$(ENTITLEMENTS)" \
		-s "$(CODESIGN_IDENTITY)" "$(APP_BUNDLE)"
```

`--timestamp` は ad-hoc では無視されるだけなので（§2）、`CODESIGN_IDENTITY=-` のフォールバック経路も分岐なしでそのまま通る。既存のコメント2ブロック（TEST_FLAGS の経緯、CODESIGN_IDENTITY の経緯）は削除しない。

### T2 — バージョン注入

`Resources/Info.plist` はテンプレートとして残し、**バンドルへコピーした後の `$(CONTENTS)/Info.plist` を書き換える**。リポジトリ内の `Resources/Info.plist` は書き換えない。

```make
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
BUILD_NUMBER ?= $(shell git rev-list --count HEAD)
```

タグが1つも無い状態では `VERSION` が空になる。**空のときは Info.plist のテンプレート値を残す**（`plutil` を呼ばない）。空文字を書き込んではいけない。

```make
	@if [ -n "$(VERSION)" ]; then \
		plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(CONTENTS)/Info.plist"; \
		plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"; \
	fi
```

順序が重要: **`plutil` による書き換えは `codesign` より前**に行う。署名後に Info.plist を書き換えると署名が壊れる。

### T3 — `make release`

新しい `release` ターゲットを追加する。既存の `bundle` / `run` / `clean` は変更しない（`clean` の削除対象に `dist` を追加するのは可）。

要件:

1. `VERSION` が空なら **エラーで停止**する（`make release VERSION=0.1.0` の明示を促すメッセージを出す）。リリース成果物にバージョン未設定は許さない
2. `CODESIGN_IDENTITY` が `-` なら **エラーで停止**する。ad-hoc の成果物を配布してはいけない
3. `bundle` を実行する
4. **署名検証**: `codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"` が成功すること
5. **DR 検証**: `codesign -d -r- "$(APP_BUNDLE)"` の出力に `$(EXPECTED_LEAF)` が含まれること。含まれなければエラーで停止（証明書の取り違え検出）
6. **zip 化は必ず `ditto` を使う**:
   `ditto -c -k --keepParent "$(APP_BUNDLE)" "dist/CasRec-$(VERSION).zip"`
   `zip -r` は拡張属性と署名構造を壊すため使用禁止
7. `dist/checksums.txt` に `shasum -a 256` の出力を書く。`dist` ディレクトリ内で相対パスになるようにする（利用者が `shasum -a 256 -c checksums.txt` で検証できる形）
8. 最後に、生成物のパスと SHA256 を標準出力に表示する

`.gitignore` に `dist/` を追加する。

### T4 — README

英語セクションと `## 日本語` セクションの**両方**に、同じ内容を追加する。片方だけの追加は不可。

配置: 英語は `## Requirements` と `## Build and run` の間に `## Install`。日本語は `### 動作環境` と `### ビルドと起動` の間に `### インストール`。

内容（過不足なく、この4点）:

1. Releases から `CasRec-<version>.zip` をダウンロードして展開し、`/Applications` へ入れる
2. **チェックサムの検証手順**（`shasum -a 256 CasRec-<version>.zip` と Releases の `checksums.txt` を比べる）
3. **初回起動が Gatekeeper にブロックされること、およびその回避手順**。macOS 15 では「右クリック → 開く」が使えないため、一度起動を試してから システム設定 → プライバシーとセキュリティ → 「このまま開く」を案内する。代替として `xattr -dr com.apple.quarantine /Applications/CasRec.app` も併記する
4. **未署名アプリであることの明示**。Apple の Developer ID による公証（notarization）を受けていないこと、開発者の自己署名証明書で署名されていること、そのため Gatekeeper の警告が出るのは想定どおりであることを、隠さず書く

トーンは既存 README に揃える（事実を述べる、誇張しない、絵文字を使わない）。「安全です」と断言しない — 利用者が自分で検証できる材料（チェックサム、ソースからのビルド手順）を示すに留める。

### T5 — `RELEASING.md`

リリース手順書。オーケストレーター（レビュアー）と将来の自分が、この文書だけでリリースを完遂できること。

含める項目:

1. 事前確認: 証明書の有効期限（`security find-certificate ... | openssl x509 -noout -dates`）
2. 品質ゲート: `swift build -Xswiftc -warnings-as-errors` と `make test`（実行件数の確認まで）
3. `make release VERSION=x.y.z`
4. 署名の確認: `codesign -d -r-` の出力が期待値と一致すること
5. **手動確認**: 実機での画面収録とマイク録音（自動化できない理由も1行添える）
6. タグ付けと `gh release create`
7. **リリースノートのテンプレート** — 毎回「未署名である旨」と「初回起動の手順」と「checksums.txt での検証方法」を書くための雛形を、コピーして使える形で置く
8. 証明書を作り直す場合の注意（§2.1 の内容へのリンクと、利用者の許可が飛ぶ旨）

---

## 5. 壊してはならない挙動

実装後、以下がすべて従来どおり動くこと。

1. `make build` — 変更なしで通る
2. `make test` — 件数が減らない（現行 69 tests / 13 suites）
3. `make bundle` — 既定の `CODESIGN_IDENTITY=CasRec Release` で成功する
4. `make bundle CODESIGN_IDENTITY=-` — ad-hoc フォールバックが成功する（README に記載済みの経路）
5. `make run` — bundle 後にアプリが開く
6. `swift build -Xswiftc -warnings-as-errors` — 警告ゼロを維持
7. `Resources/Info.plist` がリポジトリ上で書き換わっていない（`git diff` に出ない）
8. タグが存在しない状態でも `make bundle` が成功する（`VERSION` 空のフォールバック）

---

## 6. Phase B / C（今回のスコープ外、記録のみ）

**Phase B — Homebrew Cask**: `toshi0607/homebrew-tap` リポジトリを作り、cask を置く。利用者は `brew install --cask --no-quarantine toshi0607/tap/casrec` の一行になり、Gatekeeper の手順が消える。`make release` の出力（バージョンと SHA256）をそのまま cask に反映するスクリプトを足す。Releases が安定してから着手する。

**Phase C — Developer ID + notarization（$99/年）**: T1 で Hardened Runtime と entitlements を先に入れてあるため、移行時の差分は次の3点のみ。

1. `CODESIGN_IDENTITY` を `Developer ID Application: ...` に変える
2. `make release` に `xcrun notarytool submit --wait` と `xcrun stapler staple` を足す
3. `EXPECTED_LEAF` による検証を、Team ID ベースの DR 検証（`anchor apple generic and certificate leaf[subject.OU] = <TeamID>`）に置き換える

**コード本体は一切変わらない。** ただし移行の瞬間に leaf hash が変わるため、既存利用者の画面収録許可は一度飛ぶ。リリースノートで再許可を案内する必要がある。

---

## 7. Phase B — Homebrew Cask（実装仕様）

作成: 2026-08-06。Phase A（§1〜§6）完了後に着手。

### 7.1 Homebrew の quarantine に関する事実（実測で訂正済み）

| 事実 | 状態 | 根拠 |
|------|------|------|
| **`--no-quarantine` は現行 Homebrew には存在しない**（非推奨化のうえ削除済み） | VERIFIED | Homebrew 6.0.14 の `brew install --help` に無い。`brew --repository` の git log に `ffe954753b` "Prepare for deprecation of `--no-quarantine`" と `ba25213c81` "Remove leftover code for `--no-quarantine`"（2026-08-06 実測） |
| Cask 経由でインストールしても**初回の Gatekeeper 手順は消えない** | VERIFIED | 上記の帰結。当初「cask なら手順が消える」と説明したのは誤りだった |
| `brew upgrade --cask` は、**利用者が旧版を承認済み かつ 署名 identity が不変**のときに限り Gatekeeper 承認を引き継ぐ | VERIFIED | `Library/Homebrew/cask/upgrade.rb` の `quarantine_release_decision` が `:release` を返す条件。`Quarantine.signing_identity_match` が false なら `:signer_changed` で引き継がない（2026-08-06 実測） |

### 7.2 それでも Phase B をやる理由

初回の Gatekeeper 手順は消えないが、次の3点は実際に得られる。

1. **更新のたびの Gatekeeper 再承認が不要になる** — §7.1 の3行目。`CasRec Release` 証明書で署名 identity を固定してあることが、そのまま条件を満たす。Phase A の決定がここで効く
2. **チェックサム検証が自動になる** — cask の `sha256` を Homebrew が必ず照合する。README の手動手順を利用者が省略しても改ざんは検出される
3. **導入・更新・削除が一貫したコマンドになる** — `brew install` / `brew upgrade` / `brew uninstall --zap`

**「初回の Gatekeeper 手順が消える」とは、README にもリリースノートにも書かない。** 事実ではない。

### 7.3 tap リポジトリ

`toshi0607/homebrew-tap`（public）。Homebrew の命名規約により、リポジトリ名は `homebrew-` 接頭辞が必須で、利用者側では省略される（`brew tap toshi0607/tap`）。

cask の置き場所は `Casks/casrec.rb`。

### 7.4 cask の内容

```ruby
cask "casrec" do
  version "0.1.0"
  sha256 "2c79f0f9d61d279b12881b826fd418ed54f8868c2c6bcc2e79b44543f4e81e22"

  url "https://github.com/toshi0607/casrec/releases/download/v#{version}/CasRec-#{version}.zip"
  name "CasRec"
  desc "Screen recorder for macOS with application and microphone audio"
  homepage "https://github.com/toshi0607/casrec"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "CasRec.app"

  zap trash: [
    "~/Library/Preferences/dev.toshi0607.casrec.plist",
    "~/Library/Saved Application State/dev.toshi0607.casrec.savedState",
  ]
end
```

**`zap` に録画の保存先（既定 `~/Movies/CasRec`）を入れてはならない。** 利用者の録画データであり、アンインストールで消してよいものではない。

`depends_on macos: :sequoia` は `LSMinimumSystemVersion = 15.0`（= macOS 15 Sequoia）に対応する。**文字列比較形式 `">= :sequoia"` は Homebrew で非推奨**であり、シンボル形式でも `brew info` の Requirements は `macOS >= 15` になる（2026-08-06 実測）。

**caveats は書かない。** Gatekeeper の手順は README とリリースノートに集約し、cask では重複させない。

### 7.5 リリース手順への統合

`make release` が出力する version と SHA256 を cask へ反映する作業をスクリプト化する（`scripts/update-cask.sh`）。要件:

1. 引数は version 1つ。省略時はエラー終了
2. `dist/checksums.txt` から SHA256 を読む。`dist/` が無ければエラー終了（先に `make release` を促す）
3. tap リポジトリのパスは環境変数 `CASREC_TAP` で受け取る。未設定なら `../homebrew-tap` を既定とし、存在しなければエラー終了
4. cask の `version` 行と `sha256` 行だけを書き換える。他の行は触らない
5. 書き換え後に `brew audit --cask` を実行するよう促すメッセージを出す（スクリプト自身は実行しない。tap が未 tap の環境で失敗するため）
6. **コミットも push もしない。** 差分を表示して人間に委ねる

RELEASING.md に「7. Homebrew cask を更新する」の節を追加し、`gh release create` の後に置く。

### 7.6 README

英日それぞれのインストール節の先頭に Homebrew の手順を追加する。

```sh
brew install --cask toshi0607/tap/casrec
```

`--no-quarantine` を書かない（存在しない）。「初回起動は Gatekeeper にブロックされる」旨は既存の記述がそのまま適用されることを明記し、手順を重複させない。手動ダウンロードの手順は残す。

### 7.7 実測で確定した挙動（2026-08-06）

| 事実 | 状態 | 根拠 |
|------|------|------|
| `brew install --cask toshi0607/tap/casrec` は tap 未登録・trust 未設定のクリーンな状態から一行で成功する | VERIFIED | untap + trust.json 無しの状態から実行して成功。Homebrew の Tap Trust 警告は利用者の既存の他 tap に対するもので、本 cask には trust 手順が要らない |
| インストール後も `.app` の署名は無傷 | VERIFIED | `codesign --verify --deep --strict` 通過、`Authority=CasRec Release`、`flags=0x10000(runtime)`、`Timestamp=Aug 6, 2026 at 20:42:56` |
| **cask 経由でも quarantine 属性は付く**（= Gatekeeper は適用される） | VERIFIED | `xattr -p com.apple.quarantine /Applications/CasRec.app` → `0381;6a7478aa;;DD3C243F-...`。§7.1 の帰結が実物で確認された |
| チェックサムは Homebrew が自動照合する | VERIFIED | インストール時に `✔︎ Cask casrec (0.1.0)` |
| `depends_on macos: ">= :sequoia"` は非推奨形式 | VERIFIED | `Warning: Calling string comparison format for depends_on macos: is deprecated!`。シンボル形式へ修正済み |
