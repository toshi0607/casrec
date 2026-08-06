# CasRec OSS 配布 — タスク分割と Codex 委譲プロンプト

仕様の真実は [oss-distribution-spec.md](oss-distribution-spec.md)。この文書はタスクの順序、Codex へ渡すプロンプト、レビュー担当（オーケストレーター）のチェックリストを持つ。

役割分担: **実装 = Codex（GPT-5.6 Luna / `codex exec`）**、**オーケストレーション・レビュー = Claude**、**証明書と外部公開操作 = toshi0607**（[spec §3](oss-distribution-spec.md) の H1〜H4）。

## 依存関係と実行順

```
H1 長期証明書の作成 ── 完了（2026-08-06、CasRec Release / 2036-08-02 まで）
      │
      ├─ H2 秘密鍵の .p12 バックアップ ── 完了（2026-08-06）
      │
      └─ C1 署名オプション + entitlements（spec T1）
               │
               └─ C2 バージョン注入 + make release（spec T2+T3）
                        │
                        └─ C3 README + RELEASING.md（spec T4+T5）
                                 │
                         H3 実機確認 → H4 公開
```

- **C1 → C2 → C3 の直列**。C1 と C2 は `Makefile` の唯一の書き手なので並行させない。C3 は別ファイルだが、C2 で確定したコマンド文字列を引用するため後に置く。
- **1 worktree 1 writer**。Codex 稼働中はオーケストレーターも同じ worktree へ書き込まない。
- 各委譲の完了後、次を出す前にレビューする（下のチェックリスト）。**レビュー未通過のまま次へ進めない。**
- H1 は完了済みで、`EXPECTED_LEAF` の値は `4feed5cfc27c13bd9711823f1edd9a4ee2a96b44` に確定している（[spec §3.1](oss-distribution-spec.md)）。
- H2（秘密鍵の `.p12` バックアップ）は 2026-08-06 に完了済み。

## モデル配分

| タスク | 性質 | 担当 |
|--------|------|------|
| C1 署名オプション + entitlements | 仕様が確定した機械的な Makefile 編集 + 定型 plist 新規 | Codex |
| C2 バージョン注入 + make release | 仕様が確定した機械的な Makefile 追記 | Codex |
| C3 README + RELEASING.md | 文言を伴うが構成と項目は確定済み | Codex |
| 各レビュー | 設計適合と回帰の判断 | Claude（オーケストレーター） |

---

## C1 — 署名オプションと entitlements

### 委譲プロンプト

````
1. TASK
CasRec の Makefile の codesign 呼び出しに Hardened Runtime とタイムスタンプと
entitlements を追加し、entitlements ファイルを新規作成する。

2. EXPECTED OUTCOME
- 新規ファイル Resources/CasRec.entitlements が存在し、
  com.apple.security.device.audio-input のみを true で持つ
- Makefile に ENTITLEMENTS 変数と EXPECTED_LEAF 変数が定義されている
- Makefile の codesign 呼び出しが次の形になっている:
      codesign --force --options runtime --timestamp \
          --entitlements "$(ENTITLEMENTS)" \
          -s "$(CODESIGN_IDENTITY)" "$(APP_BUNDLE)"
- `make bundle` が成功し、`codesign -dvv CasRec.app` の出力に
  Authority=CasRec Release と flags=0x10000(runtime) と Timestamp= の3行が出る
- `make bundle CODESIGN_IDENTITY=-` も成功する（ad-hoc フォールバックの維持）

3. REQUIRED SKILLS
なし。

4. REQUIRED TOOLS
ファイル読み書き、シェル（make / codesign / plutil）。

5. MUST DO
- tasks/oss-distribution-spec.md の §4 T1 に書かれた plist と Makefile の
  断片を、そのとおりに使う
- Makefile の既存コメント2ブロック（TEST_FLAGS の経緯、CODESIGN_IDENTITY の
  経緯）をそのまま残す
- EXPECTED_LEAF の値は spec §4 T1 に書かれた
  4feed5cfc27c13bd9711823f1edd9a4ee2a96b44 をそのまま使う
- CODESIGN_IDENTITY の既定値を "CasRec Dev" から "CasRec Release" へ変更する。
  既存コメントの証明書名も CasRec Release に置き換えたうえで、コメント自体は残す
- 検証として次を実行し、出力を報告に含める:
      make bundle
      codesign -dvv CasRec.app 2>&1 | grep -iE 'flags|Timestamp|Authority'
      codesign --verify --deep --strict --verbose=2 CasRec.app
      make bundle CODESIGN_IDENTITY=-
      make build
      make test

6. MUST NOT DO
- 他のエージェントを起動しない。自分のツールだけで実装する
- Sources/ と Tests/ の下を一切変更しない
- Resources/Info.plist を変更しない
- entitlements に App Sandbox（com.apple.security.app-sandbox）を追加しない。
  CasRec は sandbox 化されておらず、有効にすると ffmpeg 実行と保存先が壊れる
- 画面収録用の entitlement を足さない。非 sandbox アプリでは不要で、TCC が担当する
- Makefile の build / test / run / clean ターゲットを変更しない
- release ターゲットはこのタスクでは作らない（C2 の担当）

7. CONTEXT
- リポジトリ: CasRec（macOS 画面収録アプリ、Swift Package + Makefile）
- 仕様の単一の真実: tasks/oss-distribution-spec.md
- 背景: Apple Developer Program に入らない無料構成で配布するが、将来 notarization
  へ移行する日に「マイクが動かない」を発見しないよう、Hardened Runtime と
  entitlements を先に入れておく。自己署名証明書でも --options runtime と
  --timestamp が通ることは実測済み（spec §2）
- ad-hoc 署名に --timestamp を渡してもエラーにならず無視されるだけなので、
  署名フラグを識別子ごとに分岐する必要はない（spec §2 で実測済み）
````

### レビューチェックリスト（オーケストレーター）

- [ ] `Resources/CasRec.entitlements` のキーが `com.apple.security.device.audio-input` 1つだけ。sandbox キーが混入していない
- [ ] `codesign -dvv CasRec.app` に `Authority=CasRec Release` と `flags=0x10000(runtime)` と `Timestamp=` の**3つすべて**が出る
- [ ] `codesign -d -r- CasRec.app` の leaf hash が `4feed5cf...6b44`（= `CasRec Release`）になっている
- [ ] `codesign -d --entitlements - --xml CasRec.app | plutil -p -` が `com.apple.security.device.audio-input => true` のみを出す
- [ ] `make bundle CODESIGN_IDENTITY=-` が成功する（README 記載の経路が生きている）
- [ ] `git diff --stat` が `Makefile` と新規 entitlements のみ。`Sources/` `Tests/` `Resources/Info.plist` に差分がない
- [ ] `make test` の実行件数が減っていない（現行 69 tests / 13 suites）
- [ ] `swift build -Xswiftc -warnings-as-errors` が通る
- [ ] Makefile の既存コメント2ブロックが残っている

---

## C2 — バージョン注入と `make release`

### 委譲プロンプト

````
1. TASK
CasRec の Makefile に、git タグからのバージョン注入と、配布用 zip +
チェックサムを生成する release ターゲットを追加する。

2. EXPECTED OUTCOME
- Makefile に VERSION と BUILD_NUMBER が定義され、git タグから導出される
- bundle ターゲットが、バンドルへコピーした後の Info.plist の
  CFBundleShortVersionString と CFBundleVersion を書き換える
- 新しい release ターゲットが、検証付きで dist/CasRec-<version>.zip と
  dist/checksums.txt を生成する
- .gitignore に dist/ が追加されている
- `make release VERSION=0.0.0-test` が成功し、dist/ に2ファイルが出る
- `make bundle`（タグなし・VERSION 未指定）も従来どおり成功する

3. REQUIRED SKILLS
なし。

4. REQUIRED TOOLS
ファイル読み書き、シェル（make / git / plutil / codesign / ditto / shasum）。

5. MUST DO
- tasks/oss-distribution-spec.md の §4 T2 と §4 T3 の要件を漏れなく実装する
- VERSION が空のときは plutil を呼ばず Info.plist のテンプレート値を残す。
  空文字を書き込まない
- plutil による Info.plist の書き換えは codesign より前に行う。
  署名後に書き換えると署名が壊れる
- release ターゲットは次をすべて満たす:
    (a) VERSION が空ならエラー終了し、make release VERSION=x.y.z を促す
    (b) CODESIGN_IDENTITY が "-" ならエラー終了する（ad-hoc は配布しない）
    (c) bundle を実行する
    (d) codesign --verify --deep --strict --verbose=2 が成功すること
    (e) codesign -d -r- の出力に $(EXPECTED_LEAF) が含まれること。
        含まれなければエラー終了（証明書の取り違え検出）
    (f) ditto -c -k --keepParent で zip 化する
    (g) dist/checksums.txt を shasum -a 256 で作る。dist ディレクトリ内で
        shasum -a 256 -c checksums.txt が通る相対パスにする
    (h) 生成物のパスと SHA256 を標準出力に表示する
- 検証として次を実行し、出力を報告に含める:
      make bundle
      plutil -p CasRec.app/Contents/Info.plist | grep -E 'CFBundle(Short)?Version'
      make release VERSION=0.0.0-test
      ls -la dist/
      cd dist && shasum -a 256 -c checksums.txt
      make release VERSION=0.0.0-test CODESIGN_IDENTITY=-   # エラー終了することを確認
      make release                                          # エラー終了することを確認（タグなし前提）
      git status --short Resources/Info.plist                # 差分が無いことを確認
      make build
      make test

6. MUST NOT DO
- 他のエージェントを起動しない。自分のツールだけで実装する
- Sources/ と Tests/ の下を一切変更しない
- リポジトリ内の Resources/Info.plist を書き換えない。書き換えてよいのは
  CasRec.app/Contents/Info.plist（コピー後のもの）だけ
- zip 化に `zip -r` を使わない。拡張属性と署名構造が壊れる。必ず ditto を使う
- build / test / run ターゲットの既存の挙動を変えない
- GitHub Actions のワークフローを追加・変更しない。リリース署名はローカルのみで、
  秘密鍵を CI に置かない方針である（spec §1.1）
- git tag を作らない、git commit をしない、gh コマンドを実行しない
- dist/ をコミットしない

7. CONTEXT
- 仕様の単一の真実: tasks/oss-distribution-spec.md（§4 T2 / T3 が該当）
- 直前タスク C1 で codesign に --options runtime --timestamp --entitlements と
  EXPECTED_LEAF 変数が入っている前提
- 背景: notarization を受けない配布なので、チェックサムが成果物の同一性を担保する
  唯一の手段になる。DR 検証（e）は、証明書を取り違えたビルドを配ってしまうと
  全利用者の画面収録許可が飛ぶため、その事故を機械的に止めるためのもの
- CFBundleVersion に git rev-list --count HEAD を使うのは単調増加を保つため
````

### レビューチェックリスト（オーケストレーター）

- [ ] `make release VERSION=0.0.0-test` が成功し、`dist/CasRec-0.0.0-test.zip` と `dist/checksums.txt` が出る
- [ ] `cd dist && shasum -a 256 -c checksums.txt` が OK を返す（相対パスが正しい）
- [ ] zip を展開した `.app` で `codesign --verify --deep --strict` が通る（`ditto` が使われている証拠）
- [ ] `make release VERSION=x CODESIGN_IDENTITY=-` が**エラー終了**する
- [ ] `make release`（VERSION 空）が**エラー終了**する
- [ ] `EXPECTED_LEAF` を意図的に誤った値にすると release が**エラー終了**する（検証が実際に効いているか。確認後に戻す）
- [ ] `git status --short Resources/Info.plist` が空。テンプレートが汚れていない
- [ ] `make bundle` 単体（VERSION 未指定）が成功し、Info.plist が `0.1.0` のまま
- [ ] `.gitignore` に `dist/` がある。`git status` に `dist/` が現れない
- [ ] `.github/workflows/` に差分がない
- [ ] `make test` の件数が減っていない、`swift build -Xswiftc -warnings-as-errors` が通る

---

## C3 — README と RELEASING.md

### 委譲プロンプト

````
1. TASK
CasRec の README にインストール手順を英日両方へ追加し、リリース手順書
RELEASING.md を新規作成する。

2. EXPECTED OUTCOME
- README.md の英語側に ## Install、日本語側に ### インストール が追加され、
  内容が対応している
- RELEASING.md が新規作成され、リリース作業をこの文書だけで完遂できる
- 既存セクションの文言が変わっていない

3. REQUIRED SKILLS
なし。

4. REQUIRED TOOLS
ファイル読み書き、シェル（確認用）。

5. MUST DO
- tasks/oss-distribution-spec.md の §4 T4 と §4 T5 の項目を漏れなく書く
- README は二部構成である（英語セクション群 → ## 日本語 → 日本語セクション群）。
  英語側は ## Requirements と ## Build and run の間に ## Install を、
  日本語側は ### 動作環境 と ### ビルドと起動 の間に ### インストール を置く。
  片方だけの追加は不可
- README に必ず含める4点:
    (1) Releases から zip を取得し展開して /Applications へ入れる手順
    (2) shasum -a 256 と checksums.txt によるチェックサム検証手順
    (3) 初回起動が Gatekeeper にブロックされること、および回避手順。
        macOS 15 では「右クリック → 開く」が使えないため、一度起動を試してから
        システム設定 → プライバシーとセキュリティ → 「このまま開く」を案内する。
        代替として xattr -dr com.apple.quarantine /Applications/CasRec.app も併記
    (4) Apple の公証（notarization）を受けていない自己署名アプリであることの明示
- RELEASING.md に必ず含める項目:
    (1) 証明書の有効期限確認コマンド
    (2) 品質ゲート（swift build -Xswiftc -warnings-as-errors と make test、
        実行件数の確認まで）
    (3) make release VERSION=x.y.z
    (4) codesign -d -r- の出力が期待値と一致することの確認
    (5) 実機での画面収録とマイク録音の手動確認（自動化できない理由を1行）
    (6) git tag と gh release create
    (7) リリースノートのテンプレート（未署名である旨・初回起動手順・
        チェックサム検証方法を毎回書くための、コピーして使える雛形）
    (8) 証明書を作り直す場合の注意（利用者の画面収録許可が一斉に飛ぶ旨と、
        tasks/oss-distribution-spec.md §2.1 へのリンク）
- コマンドはすべて実際に動く形で書く。プレースホルダは <version> のように
  明示し、そのまま貼れる箇所と置換が要る箇所を区別する

6. MUST NOT DO
- 他のエージェントを起動しない。自分のツールだけで実装する
- Sources/ Tests/ Makefile を一切変更しない
- README の既存セクションの文言を書き換えない。追加のみ
- 「安全です」「問題ありません」と断言しない。利用者が自分で検証できる材料
  （チェックサム、ソースからのビルド手順）を示すに留める
- 絵文字やバッジを追加しない。既存 README のトーンに揃える
- 誇張表現や宣伝文句を書かない
- Homebrew / cask に言及しない（未着手のため）
- notarization を「今後やる」と約束する書き方をしない。現状の事実のみ書く

7. CONTEXT
- 仕様の単一の真実: tasks/oss-distribution-spec.md（§4 T4 / T5 が該当）
- README.md は既に英日二部構成である。既存の見出しは
  英語: Features / Requirements / Build and run / Privacy / Legal notice / ffmpeg / License
  日本語: 主な機能 / 動作環境 / ビルドと起動 / プライバシー / 利用上の注意 / ffmpegについて / ライセンス
- 既存 README のトーンは「事実を述べる、誇張しない、絵文字を使わない」
- 背景: Apple Developer Program に入らない無料構成のため、Gatekeeper の警告は
  避けられない。隠すより先に書いたほうが信頼される、という方針で書く
````

### レビューチェックリスト（オーケストレーター）

- [ ] `## Install` と `### インストール` が**両方**あり、内容が対応している
- [ ] 挿入位置が正しい（英語: Requirements の後、日本語: 動作環境 の後）
- [ ] spec §4 T4 の4点がすべて書かれている（ダウンロード / チェックサム / Gatekeeper 回避 / 未署名の明示）
- [ ] 「右クリック → 開く」を案内していない（macOS 15 では使えない）
- [ ] 「安全です」等の断言がない。絵文字・バッジがない
- [ ] `git diff README.md` が追加のみで、既存行の変更がない
- [ ] `RELEASING.md` の8項目がすべてある
- [ ] RELEASING.md のコマンドを実際に1つずつ実行できる（証明書確認・品質ゲートは実行して確かめる）
- [ ] リリースノートのテンプレートが、そのままコピーして使える形になっている
- [ ] `git diff --stat` が `README.md` と `RELEASING.md` のみ

---

## 全体の完了条件

C1〜C3 のレビューをすべて通過したうえで:

- [ ] `swift build -Xswiftc -warnings-as-errors` が警告ゼロ
- [ ] `make test` が 69 tests / 13 suites 以上
- [ ] `make bundle` / `make bundle CODESIGN_IDENTITY=-` / `make run` が従来どおり
- [ ] `make release VERSION=0.0.0-test` の成果物が `shasum -c` と `codesign --verify` を通る
- [ ] `git status` がクリーン（`dist/` が無視されている）
- [ ] `/code-review high` を差分に対して実行し、指摘を解消した
- [ ] [todo.md](todo.md) の該当節にチェックと検証証跡を記録した
- [ ] **H1 完了後**、`EXPECTED_LEAF` と spec §2 の fingerprint を新証明書の値へ更新した
- [ ] **H3**（実機での画面収録とマイク録音）を通過した — Hardened Runtime 有効化の唯一の実証。ここが未了のうちは公開しない

その後 H4（`gh release create`）で公開する。
