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
| CLT | **26.6インストール済み**(SDK 26.5 / Swift 6.3.3)。旧13.3がブロッカーだった |
| 署名 | 有効な証明書0件。ad-hocで開始し、TCC再許可の摩擦が確認されたら自己署名証明書を導入 |
| ffmpeg | 未確認(Phase 3までに確認) |

## Assumptions

DESIGN.md §11 が主台帳。実装開始時点の追加分:

| Assumption | Status | Evidence |
|------------|--------|----------|
| 設計前提API全件(desktopIndependentWindow / movieFragmentInterval / capturesAudio / captureMicrophone / SCStreamOutputType.microphone / queueDepth / beginActivity)は実在 | VERIFIED | scratchpad probe.swift、SDK 26.5 で typecheck 全通過(2026-08-02) |
| CLTビルドの実行ファイル+手動.appバンドル(ad-hoc署名)で SwiftUI GUIアプリが起動する | VERIFIED | scratchpad MiniProbe.app: 起動→SwiftUIライフサイクル実行→自己終了 exit 0(2026-08-02)。swiftc直は -parse-as-library 必要、SwiftPMでは不要 |
| ad-hoc署名の.appでも画面収録TCCが正常に許可・維持される | UNVERIFIED-ACCEPTED (2026-08-02) | TCCダイアログ承認はユーザー操作のため自動検証不能。実機検証タスクの初手で確認する。緩和策: 摩擦(再ビルド毎の再許可)が出たら自己署名証明書に切替(DESIGN.md §8)。どの署名方式でもTCC自体は必要なためアーキテクチャへの影響なし |

## Waves

### Wave 0 — 骨格(直列。CLT 26.6完了が前提)— **完了 (c19af18)**
- [x] Package.swift(swift-tools 6.0、platforms: macOS 15、executable CasRec、Swift 6モードで警告ゼロ)
- [x] Sources/CasRec/{App,Core,Capture,Recording,PostProcess,Library,UI}/
- [x] Core/Contracts.swift — 共有型・プロトコル+CaptureEndReason(委譲先の合理的追加)。**Wave 1エージェントは変更禁止**
- [x] App/CasRecApp.swift(空ウィンドウ表示まで)
- [x] Makefile — build / bundle / run / clean
- [x] .gitignore
- 検証済(オーケストレーター再実行): `swift build` exit 0、`make bundle` で CasRec.app 生成+codesign成功、起動3秒確認 LAUNCH OK

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
- 2026-08-02: CLT 26.6インストール完了(SDK 26.5 / Swift 6.3.3)。probe全API通過、MiniProbe.appでGUI起動確認。Wave 0委譲開始(sonnet、メインcheckoutで単独writer)。
- 2026-08-02: Wave 0完了・検証済(sonnet)。Contracts.swiftにCaptureEndReasonが追加された(didStopWithErrorの中継チャネル。R10対応に必要と判断、妥当)。CaptureSourceは非Sendable(SCK型内包)— Wave 1a/1cは@MainActor寄せで対処する方針をプロンプトに明記済み。
- 2026-08-02: Wave 1並行起動(worktree分離、background): 1a Capture=sonnet / 1b Recording=opus / 1c UI=haiku。コミットはオーケストレーターが回収時に実施。
