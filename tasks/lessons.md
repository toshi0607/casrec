# Lessons

- 2026-08-02: **実装計画の前にツールチェーンの実在バージョンを確認する。** OSがmacOS 26でもCLTは13.3(Swift 5.8)だった。「OSが新しい=SDKが新しい」は成り立たない。`xcrun --show-sdk-version` と `swiftc --version` を環境確認の初手に入れる。
- 2026-08-02: **設計書のAPI前提は最小probeファイルのtypecheckで安く検証できる。** 実装前に `swiftc -typecheck` でAPI実在をVERIFIEDにする(実挙動の検証とは別物であることに注意)。
- 2026-08-02: **Agent worktree isolationはローカル未pushコミットを含まないベース(origin/main相当)から切られることがある。** 並行委譲の前提コミットがpush済みか確認するか、委譲プロンプトに「ベースコミットを確認し、異なれば `git reset --hard <expected>`」を含める(Wave 1bのopusは自力でこれをやった。1a/1cは気づかず作業した)。
- 2026-08-02: **`swift build` は親ディレクトリを遡ってPackage.swiftを拾うため、Package.swiftの無いworktreeでの「Build complete」は隣のcheckoutをビルドした偽陽性でありうる。** ビルド検証は「どのパッケージがビルドされたか」まで確認する(コンパイル対象ファイル名がログに出るかで判別)。
- 2026-08-03: **CLTのみの環境ではXCTestが存在せず、Swift Testingもframework検索パス/rpath未登録のため素の `swift test` は使えない。** `make test` にフラグを集約した。`unsafeFlags` で無理に通すと「テストを1件も実行せず exit 0」というサイレント成功になる — 「落ちない」より「実行された件数」を必ず確認する。
