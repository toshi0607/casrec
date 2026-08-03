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
- [x] 1a capture(sonnet): `Sources/CasRec/Capture/` — 回収済み(91076d8)。worktreeベース問題によりエージェント自己検証は無効だったが、メインで全層ビルド exit 0 を確認
- [x] 1b recording(opus): `Sources/CasRec/Recording/` — 回収済み(b882db7)。opusは合成サンプルバッファで状態機械を実駆動検証(30+アサーション、同秒衝突バグを自己発見・修正、実HEVC .movのfinalize確認)
- [x] 1c ui(haiku): `Sources/CasRec/UI/` — MainView / StatusView / SourcePickerView / Mocks。回収済み・メインで `swift build` exit 0(2026-08-02)
- 検証: 各worktreeで `swift build` exit 0

### Wave 2 — 統合(直列、opus委譲)

回収時検証とopus報告から確定した統合課題:

- [x] Contracts変更 (a)〜(d) — 完了(opus)。acknowledgeFailureはプロトコルasync/具象同期(Swiftの準拠規則で正当、コメント記載)
- [x] UI修正 — unsafe/ラッパー残存ゼロ(grep確認済み)、failed→Dismiss→acknowledgeFailure、visibleSources+syncSelection(選択中ウィンドウ消滅もカバー)、diskWarningバナー
- [x] App結線 — AppDelegate DI、⌘Q確認は .terminateLater + 状態追跡(preparing中のstop() no-op素通り対策)、last-window-close で終了しない
- [x] `swift build` exit 0(警告ゼロ)+ `make bundle` + 起動3秒確認(オーケストレーター再検証済み、2026-08-02)
- [ ] スリープ抑止の動作確認(pmset -g assertions)— 録画開始が必要なため実機検証に併合

Wave 2残課題(reviewerへの申し送り、既知): (1) failed時にアラートとインラインバナーが二重表示(UI設計判断待ち) (2) Mocks.swiftが参照ゼロのデッドコード(#if DEBUG化候補) (3) ⌘Q確認は録画開始直後の1ホップ分すり抜け窓あり(実害極小と判断)。**N4: L7の変更によりlast-window-close判定も同じ遅延ミラーに依存するようになった(二段構えで実害極小)** (4) 実行時挙動(⌘Qダイアログ・diskWarningバナー・スリープ抑止)は未検証 → 実機検証へ

Phase 2持ち越し追加(実機で発見): N9 セクション見出しとPickerラベルの二重表示(Mode/Codec/Resolution/FPS)— .labelsHidden() 等で整理 / N10 アプリアイコン未設定でDockのジェネリックアイコンが見つけにくい(⌘W後の復帰導線を実質的に塞ぐ。CFBundleIconFile+.icnsを追加)。なおreopenイベント(Dockクリック相当)でのウィンドウ復帰自体は2026-08-03に実機確認済み(ただし2プロセス残存状態での観測。クリーン状態の再確認は30分テストに含める)

Phase 2持ち越し追加(reviewer 2巡目 Low): N5 音声append継続失敗が完全に不可視(§5.6ログ基盤か専用カウンタで可視化) / N6 idleフレーム区間ではterminal失敗を検知できない(currentWriteFailureがwriter.statusも見るように) / N7 stopCaptureタイムアウトのdeadlineタスクにisCancelledガード(現状無害だが構造変更で顕在化) / N8 CaptureService.endedContinuationの終端後クリア / failureMessageの「残っています」不整合はdiscardIfEmpty()のBool返し化で1分岐修正可(reviewerの見積もり)

Phase 2への持ち越し(opus実測による発見): audio input が有効なのにサンプル0件だと fragmented .mov の復旧可能プレフィックスが消える(`ftyp wide mdat(0)`)。マイク拒否シナリオに加え、**既定設定(captureAppAudio=true)+対象アプリが完全無音のケースでも成立する**(reviewer L10)。kill -9 試験のマトリクスに「audio starvation(mic拒否/無音アプリの両方)」を追加すること。飢餓inputの `markAsFinished()` はR3/R8とR6のトレードオフでプロダクト判断が要るため未実装。

### Phase gate
- [x] reviewer(opus、フレッシュコンテキスト)による静的レビュー実施(2026-08-02)。※このセッションに/code-reviewコマンドが無いため、バグ検出と設計準拠をreviewer 1本でカバー(逸脱記録)
- 結果: **Request Changes** — Critical 0 / High 4 / Medium 5 / Low 10。「書き込み済み録画データを失う経路は無い」ことはVERIFIED。finalize一回保証・@unchecked Sendable根拠(5件中4件)もVERIFIED
- [x] 修正ラウンド1(opus委譲)完了・コミット済み(28f3d18): H1〜H4 / M1〜M5 / L1〜L4・L7 全14件。ビルド警告ゼロ・bundle成功をオーケストレーター再検証済み。逸脱2件(H3: 音声の非terminal失敗はdropsに数えず破棄=dropsは映像品質メトリクスのため / H4: .sourceEndedマップは.userStoppedのみ=対象クローズの実コードはPhase 2実測)
- [x] reviewer再確認: **Approve**(コードレビューとして。14件全RESOLVED、逸脱2件妥当、M1世代トークン/M2 cancellation-immunity/L4ロック外cancelのデッドロック回避まで検証済み)。Phase 1合否は実機検証待ち
- [ ] 修正ラウンド2(reviewer新規指摘、SendMessage済み): N1 colorMatrix明示(色ズレは録画に焼き付くため実機検証前必須) / N2 observeState初期yieldをロック内へ(終了不能・UI凍結の恒久化を1行で閉じる)
- [ ] PR作成
- Phase 2へ持ち越し(reviewer指摘): L5 preparingのキャンセル/タイムアウト、L6 showsCursor設定UI、L8 queue.syncの協調スレッドブロック最適化、**新規: failed時のfailureMessageが空ファイル削除後も「書き込み済みの部分は残っています」と言う不整合(修正エージェント発見。4つのユーザー向け文字列に波及するためスコープ外とした)**、**H4のR10表示精度(対象ウィンドウクローズが出す実際のSCStreamError.CodeをPhase 2のkill -9/R10試験で実測し、必要なら.sourceEndedマップに追加)**
- 記録(L9): stall検知・ディスク監視・R10分類・マイクトラックはDESIGN.md §12ではPhase 2項目だが前倒し実装済み。**前倒し分の完了条件(2時間録画・kill -9試験)はPhase 2で消化する**

### 実機検証(要ユーザー: TCC許可ダイアログ)
- [x] 画面収録権限フロー: 許可→再起動→ソース一覧+サムネイル表示 — 2026-08-03 ユーザー実機で確認(スクリーンショット証跡)
- [x] 基本録画テスト(2026-08-03、Chromeウィンドウ 7分47秒): 音声収録OK・**他プロセスの通知音(afplay 3回)非混入**・色自然(420v+709行列)・A/V同期OK・背面区間の映像継続OK。finalize後サイドカー削除、HEVC+AAC、2238×1794(Retina 2x正確・偶数丸め)、実効7.7Mbps(ピクセル比例スケールの正しい挙動)。スリープ抑止 pmset で確認済み。録画中CPU 19.8%
- [ ] DESIGN.md Phase 1完了条件: 30分録画・A/V同期・通知音非混入・4状態(背面/別Space/フルスクリーン前面/Stage Manager)でフレーム更新継続
- [ ] **色が正しいこと**(N1: 420v+colorMatrix変更の確認。BT.601/709取り違えの検出)
- [ ] **録画中に⌘W→Dockクリックでウィンドウが戻ること**(N3: 単一Windowシーンの復帰挙動は静的判定不能。戻らない場合はapplicationShouldHandleReopen+openWindow(id:)またはclose→orderOut化が必要。§5.4「close=hide」は未実装)
- [ ] スリープ抑止(pmset -g assertions)
- [ ] 結果をDESIGN.md §11(Assumption Ledger)に反映

## Notes(委譲ログ・逸脱記録)

- 2026-08-02: Xcode不在が判明(CLTのみ、しかも13.3/Swift 5.8)。DESIGN.mdの「Xcodeプロジェクト」前提を「SwiftPM + Makefileバンドル」に変更(§8/§10)。Xcode導入時はPackage.swiftを直接開けるため移行容易。
- 2026-08-02: CLT 26.6 を softwareupdate でインストール開始(bg task bbsx9jpe5)。
- 2026-08-02: probe.swift により設計前提APIの実在をSDK 13.3時点で部分VERIFIED(captureMicrophoneのみ15+ SDK待ち)。
- 2026-08-02: CLT 26.6インストール完了(SDK 26.5 / Swift 6.3.3)。probe全API通過、MiniProbe.appでGUI起動確認。Wave 0委譲開始(sonnet、メインcheckoutで単独writer)。
- 2026-08-02: Wave 0完了・検証済(sonnet)。Contracts.swiftにCaptureEndReasonが追加された(didStopWithErrorの中継チャネル。R10対応に必要と判断、妥当)。CaptureSourceは非Sendable(SCK型内包)— Wave 1a/1cは@MainActor寄せで対処する方針をプロンプトに明記済み。
- 2026-08-02: Wave 1並行起動(worktree分離、background): 1a Capture=sonnet / 1b Recording=opus / 1c UI=haiku。コミットはオーケストレーターが回収時に実施。
- 2026-08-02: Wave 1c(UI、haiku)回収。§7準拠・ビルド通過。**Wave 2統合課題**: (1) failed→idleへ戻す遷移がContractsに無くUIのリセットが機能しない → RecordingSession.start()をfailedからも受理する形に調整 (2) モード切替時にselectedSourceIdをリセット(フィルタ外ソースで録画開始できてしまう) (3) `nonisolated(unsafe)`/`@unchecked Sendable`ラッパー多用の整理(Contractsプロトコルの@MainActor化かCaptureSourceのSendable化を1a/1b実装を見て判断) (4) Mocks.swiftの#if DEBUG化検討。#Previewは未実装(Xcode不在で実害なし、不問)。
