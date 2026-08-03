# Lessons

- 2026-08-02: **実装計画の前にツールチェーンの実在バージョンを確認する。** OSがmacOS 26でもCLTは13.3(Swift 5.8)だった。「OSが新しい=SDKが新しい」は成り立たない。`xcrun --show-sdk-version` と `swiftc --version` を環境確認の初手に入れる。
- 2026-08-02: **設計書のAPI前提は最小probeファイルのtypecheckで安く検証できる。** 実装前に `swiftc -typecheck` でAPI実在をVERIFIEDにする(実挙動の検証とは別物であることに注意)。
- 2026-08-02: **Agent worktree isolationはローカル未pushコミットを含まないベース(origin/main相当)から切られることがある。** 並行委譲の前提コミットがpush済みか確認するか、委譲プロンプトに「ベースコミットを確認し、異なれば `git reset --hard <expected>`」を含める(Wave 1bのopusは自力でこれをやった。1a/1cは気づかず作業した)。
- 2026-08-02: **`swift build` は親ディレクトリを遡ってPackage.swiftを拾うため、Package.swiftの無いworktreeでの「Build complete」は隣のcheckoutをビルドした偽陽性でありうる。** ビルド検証は「どのパッケージがビルドされたか」まで確認する(コンパイル対象ファイル名がログに出るかで判別)。
- 2026-08-03: **CLTのみの環境ではXCTestが存在せず、Swift Testingもframework検索パス/rpath未登録のため素の `swift test` は使えない。** `make test` にフラグを集約した。`unsafeFlags` で無理に通すと「テストを1件も実行せず exit 0」というサイレント成功になる — 「落ちない」より「実行された件数」を必ず確認する。
- 2026-08-03: **ad-hoc署名のTCC問題は「許可しても拒否しても毎回ダイアログ」という症状で顕在化する**(システム設定のエントリが旧cdhashに紐づき新バイナリに効かない)。解決: 自己署名コード署名証明書(Keychain Accessの証明書アシスタントで作成、macOS 26では `/System/Library/CoreServices/Applications/` にありSpotlightに出ない)+ `tccutil reset <service> <bundle-id>` で壊れたレコードを掃除。**自己署名証明書は信頼設定(パスワード)なしでもcodesignに使える**(`find-identity -v` が "0 valid" と言っても実署名は通る)。
- 2026-08-03: **tasks/todo.md の本文に「UNVERIFIED」という文字列を書くと Stop hook(check-ledgers.sh)が台帳未決着と誤検知してブロックする。** 台帳(## Assumptions / DESIGN.md §11)の状態語はステータス列でのみ使い、説明文中の言及は「未検証」と書く。同じ誤検知を2回踏んだ(PR #5記録時・PR #11記録時)。
