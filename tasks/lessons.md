# Lessons

- 2026-08-02: **実装計画の前にツールチェーンの実在バージョンを確認する。** OSがmacOS 26でもCLTは13.3(Swift 5.8)だった。「OSが新しい=SDKが新しい」は成り立たない。`xcrun --show-sdk-version` と `swiftc --version` を環境確認の初手に入れる。
- 2026-08-02: **設計書のAPI前提は最小probeファイルのtypecheckで安く検証できる。** 実装前に `swiftc -typecheck` でAPI実在をVERIFIEDにする(実挙動の検証とは別物であることに注意)。
