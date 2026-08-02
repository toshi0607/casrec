# CasRec Phase 1 実装計画

[DESIGN.md](../DESIGN.md) §12 Phase 1 に基づく。ブランチ: `feat/phase-1`。オーケストレーション方針: タスクごとに新しいコンテキストのサブエージェントへ委譲(モデルはタスク性質で選択)、独立部分はworktree分離で並行。

## Constraints

| Constraint | Source | Verify by |
|------------|--------|-----------|
| 設計はDESIGN.mdに従う。逸脱はNotesに記録し設計書も更新 | user / DESIGN.md | reviewerのPhase gate |
| タスクごとにサブエージェント委譲、モデルはタスク性質で選択 | user msg 2026-08-02 | Notesの委譲ログ |
| 並行可能な部分は並行実行。1 worktree 1 writer | user msg / behavior.md | Wave構成 |
| オーケストレーターは実装エージェント稼働中の成果物に書き込まない | memory | - |
| コミットはfeat/phase-1系ブランチのみ。mainへ直接pushしない | pr.md | git log |
| Phase 1完了 = DESIGN.md §12の完了条件を満たす(CI無しのため手動検証記録) | pr.md / DESIGN.md | 本ファイルに証跡記録 |

## 環境

| 項目 | 状態 |
|------|------|
| Xcode | **無し**。SwiftPM + CLTで開発(DESIGN.md §8/§10をSwiftPM方式に更新済み) |
| CLT | 13.3(Swift 5.8)→ **26.6へ更新中**(旧SDKがブロッカーだった) |
| 署名 | 有効な証明書0件。ad-hocで開始し、TCC再許可の摩擦が確認されたら自己署名証明書を導入 |
| ffmpeg | 未確認(Phase 3までに確認) |

## Assumptions

DESIGN.md §11 が主台帳。実装開始時点の追加分:

| Assumption | Status | Evidence |
|------------|--------|----------|
| 主要API(desktopIndependentWindow / movieFragmentInterval / capturesAudio / queueDepth / beginActivity)は実在 | VERIFIED | scratchpad probe.swift が SDK 13.3 でも typecheck 通過(2026-08-02) |
| captureMicrophone / SCStreamOutputType.microphone は 15+ SDK が必要 | VERIFIED | 同probe: SDK 13.3 で該当2件のみエラー。CLT 26.6 導入後に再検証 |
| SwiftPM executable + 手動.appバンドルで SwiftUI GUIアプリが動く(TCCも機能する) | UNVERIFIED | Wave 0 の make bundle + 起動確認で検証 |

## Waves

### Wave 0 — 骨格(直列。CLT 26.6完了が前提)
- [ ] Package.swift(swift-tools 6.x、platforms: macOS 15、executable CasRec)
- [ ] Sources/CasRec/{App,Core,Capture,Recording,PostProcess,Library,UI}/
- [ ] Core/Contracts.swift — 共有型・プロトコル(RecordingState、CaptureTargetKind、SampleSink等)。**Wave 1エージェントは変更禁止**
- [ ] App/CasRecApp.swift(空ウィンドウ表示まで)
- [ ] Makefile — build / bundle(.app生成: Info.plist(NSMicrophoneUsageDescription含む)+ ad-hoc codesign)/ run
- [ ] .gitignore(.build/, *.app 等)
- 検証: `swift build` exit 0、`make bundle` で CasRec.app 生成、起動でウィンドウ表示

### Wave 1 — 並行実装(worktree分離。担当領域外への書き込み禁止、Contracts変更は報告のみ)
- [ ] 1a capture(sonnet): `Sources/CasRec/Capture/` — ShareableContentProvider(列挙+サムネイル+2秒更新)、CaptureService(SCStream開始/停止/エラー中継)
- [ ] 1b recording(opus): `Sources/CasRec/Recording/` — AssetWriterCoordinator(fragmented .mov、A/V同期、finalize保証)、SessionGuards、RecordingSession状態機械
- [ ] 1c ui(haiku、失敗時sonnet): `Sources/CasRec/UI/` — RecordView / StatusView / SourcePicker(Contracts準拠のモックで動作)
- 検証: 各worktreeで `swift build` exit 0

### Wave 2 — 統合(直列)
- [ ] 3ブランチをfeat/phase-1へマージ、App層でDI結線
- [ ] `swift build` + `make bundle` + 起動確認
- [ ] スリープ抑止の動作確認(pmset -g assertions)

### Phase gate
- [ ] /code-review high(バグ)+ reviewer(DESIGN.md準拠)
- [ ] findings対応 → PR作成

### 実機検証(要ユーザー: TCC許可ダイアログ)
- [ ] DESIGN.md Phase 1完了条件: 30分録画・A/V同期・通知音非混入・4状態(背面/別Space/フルスクリーン前面/Stage Manager)でフレーム更新継続
- [ ] 結果をDESIGN.md §11(Assumption Ledger)に反映

## Notes(委譲ログ・逸脱記録)

- 2026-08-02: Xcode不在が判明(CLTのみ、しかも13.3/Swift 5.8)。DESIGN.mdの「Xcodeプロジェクト」前提を「SwiftPM + Makefileバンドル」に変更(§8/§10)。Xcode導入時はPackage.swiftを直接開けるため移行容易。
- 2026-08-02: CLT 26.6 を softwareupdate でインストール開始(bg task bbsx9jpe5)。
- 2026-08-02: probe.swift により設計前提APIの実在をSDK 13.3時点で部分VERIFIED(captureMicrophoneのみ15+ SDK待ち)。
