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
| 署名 | ~~ad-hoc~~ → **自己署名証明書「CasRec Dev」に切替済み(2026-08-03)**。ad-hocはリビルド毎にTCC許可が無効化される摩擦が実際に発生(§8の予見どおり)。tccutilで壊れたレコードを掃除し、証明書署名でdesignated requirementを安定化 |
| ffmpeg | 未確認(Phase 3までに確認) |

## Assumptions

DESIGN.md §11 が主台帳。実装開始時点の追加分:

| Assumption | Status | Evidence |
|------------|--------|----------|
| 設計前提API全件(desktopIndependentWindow / movieFragmentInterval / capturesAudio / captureMicrophone / SCStreamOutputType.microphone / queueDepth / beginActivity)は実在 | VERIFIED | scratchpad probe.swift、SDK 26.5 で typecheck 全通過(2026-08-02) |
| CLTビルドの実行ファイル+手動.appバンドル(ad-hoc署名)で SwiftUI GUIアプリが起動する | VERIFIED | scratchpad MiniProbe.app: 起動→SwiftUIライフサイクル実行→自己終了 exit 0(2026-08-02)。swiftc直は -parse-as-library 必要、SwiftPMでは不要 |
| ad-hoc署名の.appでも画面収録TCCが正常に許可・維持される | VERIFIED-部分反証で決着 (2026-08-03) | 実測: 許可自体は可能だが**再ビルド毎にcdhash変化で権限が無効化**(ユーザー報告「許可しても拒否しても毎回ダイアログ」)。緩和策どおり自己署名証明書 CasRec Dev へ切替(bd71ea9、Makefile既定)+tccutil resetで解決。以後のコード変更リビルド(CFBundleVersion変更時・PR #3検証時の計2回)で権限ダイアログ再表示なしを確認 → tasks/lessons.md に手順記録済み |

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
- [x] 長時間録画テスト(2026-08-03、YouTube再生ウィンドウ **1時間47分54秒**完走): finalize成功・サイドカー削除・HEVC+AAC・全時間軸シーク可。⌘W→reopen復帰もクリーン状態で成功(N3クローズ)
- **重要発見(別Space黒画面)**: 対象ウィンドウを別Space(デスクトップ)へ切り替えた時点から**動画プレーヤー領域のみ黒**、ページUI(タブ名・コントロール)は録画終了まで更新継続。= SCKキャプチャは生きているが、**Chromeのocclusion最適化が不可視ウィンドウの動画デコード描画を停止**したもの。フレームは供給され続けるためdrops/stall検知には映らない(検知不能の盲点)。フルスクリーンアプリ前面は「別アプリの映像の映り込みは無し」を確認(黒画面は別Space起因で継続中だったため単独判定は不能)
- [x] DESIGN.md Phase 1完了条件(2026-08-03、計3本の実録で消化): 基本7分47秒+長時間**1時間47分54秒**完走・A/V同期・通知音非混入。4状態: 同一Space背面=OK / 別Space=動画要素黒(ソースアプリの描画抑制、音声・UIは継続。**ユーザー判断で対応スコープ外**、§9に制約記載) / フルスクリーン前面=映り込み無し / Stage Manager=未実施(ユーザー普段非使用のためスキップ)
- [x] **色が正しいこと** — ユーザー目視で自然と確認(420v+709行列)
- [x] **録画中に⌘W→reopen復帰** — クリーン1プロセス状態で成功(N3クローズ。ただしDockアイコン未設定で見つけにくい→N10)
- [x] スリープ抑止 — pmset で CasRec の PreventUserIdleSystemSleep/DisplaySleep を確認
- [x] 結果をDESIGN.md §11(Assumption Ledger)・§9(制約)に反映済み

**Phase 1 完了(2026-08-03)。** 次期の最優先実装はユーザーの本命ニーズ「**ウィンドウ内の動画領域だけを矩形で切り出して録画**」(元Phase 3の矩形領域を繰り上げ。ウィンドウフィルタ+sourceRectならアプリ音声分離を維持したまま領域切り出しが可能 — ディスプレイフィルタ方式より優位。設計改訂は次PRで)

### 人間レビュー対応(PR #2、2026-08-03)

指摘3件(Request changes相当)— 全対応済み(b45d188):
- [x] (1) Medium: writer失敗検知 — stats照会(ticker毎秒)ごとに writer.status == .failed をラッチ。append経由は早期検知として残置。クラスdocの無条件保証2箇所を条件付きに修正
- [x] (2) 要判断: audio starvation — Phase 2持ち越し維持+DESIGN.md §5.3に「条件付き」明示(0c4432a)+コードコメント修正(b45d188)
- [x] (3) Low: テストターゲット — **18テスト/3スイート全パス(0.17s)**。停止経路競合(manual×streamFailure)、failed→acknowledge→idle、成果物削除規則、finishWriting一回保証、(1)の回帰2件。**変異テストで検出力確認**(対応1を戻す/排他を弱める→該当テストが失敗)、8回連続でflaky無し
- 残課題(Phase 2へ): disk critical経路の競合テストは SessionGuards のプロトコル化が必要なため未カバー(停止3経路中2経路カバー)。CI(GitHub Actions macOSランナーで swift build+test)の追加もPhase 2初手候補
- 環境知見: **CLTにXCTest無し。Swift TestingはCLT内にあるがSwiftPM未登録のため素の `swift test` は不成立 → `make test` に検索パス/rpathを集約**(unsafeFlags案は「テスト0件でexit 0」のサイレント成功になるため却下)。Xcode導入後は素のswift testも動く

## Notes(委譲ログ・逸脱記録)

- 2026-08-02: Xcode不在が判明(CLTのみ、しかも13.3/Swift 5.8)。DESIGN.mdの「Xcodeプロジェクト」前提を「SwiftPM + Makefileバンドル」に変更(§8/§10)。Xcode導入時はPackage.swiftを直接開けるため移行容易。
- 2026-08-02: CLT 26.6 を softwareupdate でインストール開始(bg task bbsx9jpe5)。
- 2026-08-02: probe.swift により設計前提APIの実在をSDK 13.3時点で部分VERIFIED(captureMicrophoneのみ15+ SDK待ち)。
- 2026-08-02: CLT 26.6インストール完了(SDK 26.5 / Swift 6.3.3)。probe全API通過、MiniProbe.appでGUI起動確認。Wave 0委譲開始(sonnet、メインcheckoutで単独writer)。
- 2026-08-02: Wave 0完了・検証済(sonnet)。Contracts.swiftにCaptureEndReasonが追加された(didStopWithErrorの中継チャネル。R10対応に必要と判断、妥当)。CaptureSourceは非Sendable(SCK型内包)— Wave 1a/1cは@MainActor寄せで対処する方針をプロンプトに明記済み。
- 2026-08-02: Wave 1並行起動(worktree分離、background): 1a Capture=sonnet / 1b Recording=opus / 1c UI=haiku。コミットはオーケストレーターが回収時に実施。
- 2026-08-02: Wave 1c(UI、haiku)回収。§7準拠・ビルド通過。**Wave 2統合課題**: (1) failed→idleへ戻す遷移がContractsに無くUIのリセットが機能しない → RecordingSession.start()をfailedからも受理する形に調整 (2) モード切替時にselectedSourceIdをリセット(フィルタ外ソースで録画開始できてしまう) (3) `nonisolated(unsafe)`/`@unchecked Sendable`ラッパー多用の整理(Contractsプロトコルの@MainActor化かCaptureSourceのSendable化を1a/1b実装を見て判断) (4) Mocks.swiftの#if DEBUG化検討。#Previewは未実装(Xcode不在で実害なし、不問)。

### PR #3 レビュー+実機検証(矩形録画、外部エージェント実装、2026-08-03)

静的レビュー(オーケストレーター実施):
- [x] 指示文(rect-capture-brief.md)の要件8項目すべて充足を diff で確認。禁止事項違反なし(tasks/未編集・Recording層無変更・空catch/コメントアウト無し・conventional commit)
- [x] `swift build` 警告ゼロ / `make test` 22件(既存18+新規4)全パス / `make bundle` exit 0・CasRec Dev署名 — すべて自分の環境で再実行して確認
- [x] 新規テストの検出力を変異で確認: contentRect()のY軸スケールをX軸に差し替え→「origin and scale preserved」テストが期待どおり失敗(y 40→60)。復元済み
- [x] ID形式(`window-N`/`display-N`)によりモード切替で必ずselectedSourceIdが変わりonChange→clearCrop()が発火することを確認。仮に残ってもmakeConfigurationのinvalidCrop throwで防御される二重構え

実機検証(sourceRect挙動 — §11の未検証項目を消化。§11のVERIFIED化はc652ec2で反映済み、リサイズ時挙動はDESIGN.md §11の別行(未検証、Phase 2で実測)として管理):
- [x] **座標系VERIFIED**: 4象限色分けテストページ(Safari 934×841pt)で境界跨ぎcrop(444×552pt)を録画。出力888×1104pxの緑→黄境界がy=632pxに出現し、選択位置からの期待値(~620px、目測誤差±10px)と一致。**原点=左上・単位=ポイント・スケール(pointPixelScale)すべて正しい。WYSIWYG成立**
- [x] 出力解像度: バッジ表示(36×528 / 888×1104)とmdlsの実ピクセルが両録画とも完全一致。サイドカー掃除・音声2chも正常
- [x] 全体録画の互換(crop=nil): 1868×1682で内容正常・黒帯なし。クリア→全体録画の遷移もUIで確認
- [x] リビルド後のTCC維持: 自己署名証明書によりコード変更後の再ビルドでも権限ダイアログ再表示なし(3録画すべて即開始)
- 記録: 検証録画3本が ~/Movies/CasRec/ に残存(Safari-20260803-185433/185841/190134.mov、計~9MB)。不要なら削除可
- **異常1件(製品コード起因ではないと判断)**: UI自動化の合成ドラッグイベント(left_click_drag)がDragGestureに正しく解釈されず異常選択(36×528)が確定された1回のみ、出力下端45pxが黒(=範囲外rectをSCKが黒埋めする挙動)。通常のドラッグ操作(実験B)では表示・録画・境界位置が完全一致し再現せず。クランプ(clampedContentRect)は録画開始時に毎回通る設計のため、実操作での発生経路は未発見。ユーザー実利用で下端黒帯を見かけたら要報告

軽微所見(マージブロッカーではない、Phase 2候補):
- ~~N11~~ / ~~N12~~: レビューコメント投稿後、追いコミットc652ec2(バッジのスケールを幅高さ独立で計算+CGSize版outputSize、部分はみ出しclampテスト追加)で対応済み。マージ後コード(ad4ba3a相当)で警告ゼロ・`make test` 23件全パス再確認済み(2026-08-03)
- N13: シート再オープン時に既存選択を引き継がない(毎回まっさら)
- N14: バッジのピクセルサイズはscalePercent=100基準(領域サイズ表示としては正しい)

### PR #5 レビュー+実機確認(Phase 2磨き込みバッチ、外部エージェント実装、2026-08-03)

- [x] 静的レビュー: 8項目対応・項目別コミット9本・禁止事項遵守を確認。項目6は指示以上(UUID世代管理+finish()追加)だが消費側の初回break構造と整合し安全と判断
- [x] レビュー側再検証: 警告ゼロ / `make test` 26件(23+新規3)全パス / bundle にAppIcon.icns配置・署名成功
- [x] 実機確認: ラベル二重解消(4箇所)/ シート再オープンで選択復元(888×1104で決定→再オープン→同一選択表示)/ Audio Failures 0時非表示 / crop録画回帰なし(バッジ=出力888×1104) — いずれもVERIFIED
- [x] CI: PR上でpass(56s)。Makefileのwildcard分岐後もローカルCLTの`make test`は従来どおり成功
- 未消化: Dockアイコンの見た目はユーザー目視待ち(icns実物・CFBundleIconFile・バンドル配置は確認済み)。Audio Failures >0 の実機表示は人為的再現不能のためコードレビューのみ
- 記録(軽微): discardIfEmptyの削除I/Oエラー時はrecordingRemains=trueになり空ファイル残存でも「保存されています」と出るエッジあり(実害極小、対応不要と判断)
- 検証録画1本追加: Safari-20260803-201451.mov(~/Movies/CasRec/、削除可)
