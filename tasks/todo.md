# CasRec Phase 1 実装計画

[DESIGN.md](../DESIGN.md) §12 Phase 1 に基づく。ブランチ: `feat/phase-1`。オーケストレーション方針: タスクごとに新しいコンテキストのサブエージェントへ委譲(モデルはタスク性質で選択)、独立部分はworktree分離で並行。

## 公開前のライセンス・適法利用案内（2026-08-05）

- [x] リポジトリ構成・既存ビルド手順・未コミット変更を確認する。
- [x] MIT ライセンス、英日 README、設計書の目的・利用範囲を公開方針に合わせて更新する。
- [x] 初回起動時の注意表示とマイク付近の補足を、録画パイプラインを変更せずに追加する。
- [x] 確認状態のユニットテスト、既存テスト、ビルドを実行し、レビュー結果を記録する。

### 判断ログ

- 注意表示の確認状態は `UserDefaults` に注意文の確認済みバージョンを保存する。文言を大きく変更した際は定数のバージョンを上げることで再表示できる。
- 既存の録画機能には変更を加えず、注意表示と公開向け文書に限定する。
- 注意シートは契約同意ではなく、適法利用の案内を確認したことを記録する操作とする。明確化に伴い確認済みバージョンを2へ上げ、既存利用者にも再表示する。

### レビュー結果

- `make test`、`make build`、`make bundle` は成功。注意表示の未確認・確認済み・旧バージョンの再表示を隔離した `UserDefaults` で検証した。
- 録画パイプライン、ScreenCaptureKit設定、保存形式、ffmpeg検出・実行経路は変更していない。
- 初回シートの目視、終了ボタン、実際のTCC権限を伴う録画はGUI環境での手動確認が必要。
- MIT Licenseの無保証・責任制限をREADMEの利用上の注意から明示リンクし、注意シートと実装コメントの非契約性を同じ表現で揃えた。

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

### PR #7 レビュー+実機確認(ライブラリ画面+保存先変更、外部エージェント実装、2026-08-03)

- [x] 静的レビュー: 要件9項目対応・Capture/Recording層無変更・テストの実録画ディレクトリ非使用を確認。保存先解決の純粋化/実書込プローブ/ユーザー選択ディレクトリの暗黙再作成回避/サイドカー同時ゴミ箱移動はいずれも良判断
- [x] 再検証: 警告ゼロ / `make test` 33件(26+新規7)全パス / bundle成功 / CI緑
- [x] 実機確認(全VERIFIED): タブUI・一覧(新しい順/実サムネイル/日時・時間・サイズ正確)・QuickLook・ゴミ箱移動(確認ダイアログ→7本→6本、Safari-185433を削除)・NSOpenPanel表示(現保存先初期位置)・録画finalize後のライブラリ自動反映・録画回帰なし
- 軽微所見(Phase 2候補): (a) ライブラリタブ表示中の録画失敗アラート表示は未検証(alertがrecordingTab配下へ移動したため) (b) scanはduration全件取得までバリア(数十本なら実用問題なし) (c) isUsable自体の実FSテスト無し (d) 未finalizeバッジは単体テストのみ(実機にサイドカー付きファイル無し)
- 保存先の実変更(NSOpenPanelで別フォルダ選択→UserDefaults反映)はパネル選択がOS標準のため未実施(解決・保存ロジックはテスト済み)

### PR #9 レビュー+実機確認(圧縮・GIF・修復+ジョブキュー、外部エージェント実装、2026-08-03)

- [x] 静的レビュー: 要件11項目対応・原本非破壊(-nの二重ガード)・shell不使用の引数配列・純粋関数化+テスト。**Medium指摘1件**: FfmpegRunnerのstderr読み取りがwaitUntilExit後でパイプバッファ64KB超時にデッドロック(長尺GIF変換で現実に発生しうる)→ 追いコミット6f3667cで解決(read先行+quietArguments二重対策、テスト更新)。修正後バイナリで修復再実行し回帰なし+連番回避 -recovered-2.mov の実機確認も完了(2026-08-03)
- [x] 再検証: 警告ゼロ / `make test` 41件(35+新規6)全パス / bundle成功 / CI緑
- [x] 実機確認: GIF変換(インジケータ→完了→自動反映、幅640出力正常)/ 修復(実kill -9由来の未finalizeファイルで-recovered.mov生成、原本・サイドカー非破壊、再生可能)/ ffmpeg不在時(バナー+GIF・修復disabled+圧縮有効。バイナリ一時退避で確認、復元済み)/ 未finalizeバッジ初の実機表示
- [x] **kill -9試験の一部前倒し消化(Phase 2)**: 映像のみ(App Audioオフ)の録画を15秒でkill -9 → 生のfragmented .movが直接再生可能(20.1秒・1840×872、フレーム抽出OK)= R6クラッシュ耐性の実証。audio starvationケース(音声有効・無音)のkill -9は未消化
- [x] 圧縮: UI操作(サブメニュー)のみ自動化不能のため、実行部を等価スクリプトで検証 — AVAssetExportPresetHEVC1920x1080変換成功+**7分動画でprogressプロパティ単調増加を確認**(新export(to:as:)APIでも進捗表示が機能する)。UI 1クリックの確認のみ残(ユーザー実操作で完結)
- 未消化(実害小): ジョブキュー直列・進捗%表示の実機目視(単体テスト・等価検証でカバー)、同一ソース重複エンキューのUI挙動
- 検証成果物: Safari-205529.gif / Finder-213935.mov+.recording / Finder-213935-recovered.mov が ~/Movies/CasRec/ に残存(削除可)

### PR #11 レビュー+実機確認(予約録画タイマー、外部エージェント実装、2026-08-03)

- [x] 静的レビュー: 仕様10項目対応・クロック注入の決定的テスト(仮想時計)・Recording/Capture層無変更。**Medium指摘1件**: 上限自動停止が「予約とは別の手動録画」を止めうる誤爆エッジ(発火時idleガードは開始後の手動介入をカバーしない)→ 追いコミット9de7bb5で全解決(startedAt完全一致照合+誤爆テスト追加。Low2件もScheduledSleepGuard化・過去時刻バナー拒否で対応)。修正後バイナリで過去時刻拒否・assertion登録・23:37予約→23:37:25自動開始の実機回帰を確認(2026-08-03)
- [x] 再検証: 警告ゼロ / `make test` 50件(41+新規9)全パス / bundle成功 / CI緑
- [x] 実機確認: **実時刻での予約発火**(22:53予約→22:53:15録画自動開始、ソース再解決ID経路込み)/ 待機中スリープ抑止assertion登録→録画中assertionへの引き継ぎ(pmsetで確認)/ キャンセルでassertion即解除 / 予約UI(既定+10分・予約済み表示・注記)
- 実機未消化(テスト担保): 自動停止(最小プリセット30分のため)、フォールバック再解決3経路、idle以外スキップ、スリープ明け発火(DESIGN.md §11の未検証行として管理、Phase 2実機試験で消化)
- 検証録画1本追加: Safari-20260803-225315.mov(予約発火の実録、削除可)

### PR #13 レビュー+実機確認(メニューバー常駐+ホットキー、外部エージェント実装、2026-08-04)

- [x] 静的レビュー: 仕様9項目対応・RegisterEventHotKey方式遵守(global monitor不使用)・開始前チェックの3経路共通化(RecordingControls/startRecordingIfReady)・トグル判定純粋関数+4テスト。**Low〜Medium指摘1件**: ホットキー起因のクイック開始失敗時、mainWindowRequestのonChangeがMenuBarExtraコンテンツ(メニュー表示中のみ評価)にあるためウィンドウ自動オープンが機能しない可能性 → **2往復で解決**: ff17899(MainViewのonChange方式)は閉じたWindowシーンでonChange不発のため実機再現2回で反証、NSApp.windowsからidentifier "main"をmakeKeyAndOrderFrontする案を再提示 → 582904f/f934186で採用され、**ウィンドウ閉+失敗→自動オープン+バナー表示を実機VERIFIED**(2026-08-04)。mainWindowRequest機構は削除され簡素化。通常経路の回帰なし
- [x] 挙動変更の記録: last-window-close時の自動終了を廃止(常駐化の帰結、終了導線はメニュー+⌘Q)
- [x] 再検証: 警告ゼロ / `make test` 56件(52+新規4)全パス / bundle成功 / CI緑
- [x] 実機確認: ⌥⌘R開始/停止トグル(ウィンドウ開・閉両状態)/ ⌘W後のプロセス生存(常駐)/ 閉状態でのクイック開始(再解決経由、Safari-20260804-001602.mov)— いずれもVERIFIED。権限ダイアログ非発生(RegisterEventHotKeyの狙いどおり)
- 未消化→解消: メニューバーアイテムは**ユーザー目視で表示確認済み**(Ice+ノッチ環境で常時視認は制限=環境要因)。メニュー項目のクリック操作のみ自動化不能で未実施(ホットキーが同一のtoggleQuickRecording経路を通り実質カバー)。§11のRegisterEventHotKey行はVERIFIED化可(次回docs更新で反映)。別Spaceのウィンドウはクイック開始の再解決に失敗する(SCK列挙のonScreen特性、§9既知制約の同族)
- 検証録画2本追加(削除可): Safari-20260804-001433.mov(ホットキー開始)/ Safari-20260804-001602.mov(閉状態開始)

### PR #15 レビュー+実機確認(Phase 2信頼性・整理バッチ、外部エージェント実装、2026-08-04)

- [x] 静的レビュー: 6項目対応・**Recording層の変更線引き完全遵守**(RecordingSession+SessionGuardsプロトコルのみ、Contracts/Coordinator/CaptureService無変更、既存テスト無修正)。preparingタイムアウトはPreparationRace+世代トークンの多層防御+遅延成功時のストリーム解放まで実装
- [x] disk critical競合テスト追加で停止3経路の競合カバレッジ完備(FakeSessionGuardsは本物の閾値に触れない純粋ダブル)
- [x] failed表示一本化(アラート廃止→バナー+メニューバーexclamationmarkアイコン)、AppDelegate状態ミラー統一、Mocks.swift削除、§11更新(ホットキーVERIFIED/L8見送り/アラート行解消)
- [x] 再検証: 警告ゼロ / `make test` 59件(56+新規3)×5回連続全パス / bundle成功 / CI緑
- [x] 実機確認: 回帰(⌥⌘Rトグル録画→停止→finalize正常)+**偶然のレース実証**(列挙遅延中の二重⌥⌘Rでも録画1本のみ=start原子ガードの実機確認)
- 実機未消化(担保根拠明記): preparingタイムアウト発火(人為再現不能→注入クロックテスト2件で担保)/ failedバナー・メニューバーfailedアイコン(failed状態の人為再現不能→既存表示の実績+宣言的コードで担保)

### PR #17 レビュー+長時間実録の記録(2026-08-05)

- [x] PR #17(領域選択ドラッグの座標ずれ修正): 原因は当方がコード特定(gestureが.positionの外側でキャンバス座標が届き、黒帯オフセットが二重加算)。修正は指示どおり(coordinateSpace明示+imageLocalSelectionRect純粋関数+黒帯3ケーステスト)。警告ゼロ/62件全パス/CI緑。実機のドラッグ一致はユーザー確認(LGTM)。※PR #3検証時の「合成ドラッグの謎挙動」もこのバグで説明がつく
- [x] **長時間実録(2026-08-04)**: ブラウザ上の動画配信(Chrome、矩形1714×946、アプリ音声)を**6時間37分34秒・7.15GB**でfinalize完走。全時間軸シーク可(冒頭/中間/末尾のフレーム抽出OK)。過去最長(1時間47分)を大幅更新。ffmpeg -c copyで先頭2時間45分を無劣化切り出し(-trimmed.mov、4.05GB)
- **メモリ定量計測は失敗**(オーケストレーターの計測スクリプトが「最初の録画終了で自己終了」する単発設計だったため、本番前の短い録画で消費された)。複数録画対応の常駐型に改良済み、次回の長時間録画で再挑戦。§12 Phase 2完了条件「2時間でメモリ横ばい」の定量部分は未消化のまま
- 運用観察: 手動開始には録画時間上限が無く、配信終了後3.5時間録り続けた(ユーザーは自動停止を期待)→ 上限の全経路適用を次タスクとして委託(feat/duration-limit)

### PR #19 レビュー+実機検証(録画時間上限の全経路適用、外部エージェント実装、2026-08-05)

- [x] 静的レビュー: 仕様1〜8対応。既存のstartedAt照合をscheduleAutoStopとして公開API化+キーをreservationID→独立autoStopIDに変更し、予約と直接開始のタイマーが干渉しない設計。RecordingSettings/Recording/Capture層は無変更。**Low指摘1件**: durationLimitBannerMessageがクリアされない(他2バナーは新規アクション時にクリア)→ 追いコミット333a24bでrecordingDidStart()に集約して解決(3経路すべてカバー)
- [x] **検証は隔離クローンで実施**: メインcheckoutに別セッションの未コミット作業(LICENSE/README/DESIGN.md汎用化/利用上の注意シート)があり、テスト件数が68件になってPR記載66件と不一致だったため。隔離クローンでは66件・12スイート全パス(PR記載と一致)・警告ゼロ・CI緑
- [x] **変異テストで安全ガードの検出力を独立確認**: startedAt照合を緩めると予約・直接開始の両「never stops a newer recording」テストが失敗、復元で全パス
- [x] 実機検証(全VERIFIED): Settings欄への上限Picker移動 / 永続化(UserDefaults `thirtyMinutes`+再起動後復元) / HUD「上限 00:30」/ **自動停止の実発火 — 実尺1800.32秒(誤差0.3秒)でfinalize正常・サイドカー掃除済み** / 停止バナー表示。**auto-stopの実発火はPR #11実装以来はじめての実機検証**
- [x] TCC知見: 別パスのバンドル(隔離クローンのCasRec.app)でも自己署名証明書により画面収録許可が継承され、再許可不要だった
- **初のメモリ定量データ(30分)**: RSS min 107.5 / max 127.8 / avg 117.4 MB、30サンプル。113→108→113→117→121→124→128MBと緩やかな単調増加。破綻はしないが「横ばい」とは言い切れない。§12 Phase 2完了条件の2時間計測は継続課題(長時間側の外挿はしない)

### モダンUIリデザイン(方向性「デッキ」、2026-08-05)

ユーザー指示: 「プロトタイプなのでモダンなデザインにしてください」。方向性は3案(デッキ/モニター/コンソール)を提示し、**デッキ**を選択。実装は他のコーディングエージェントへ委譲し、当方はタスクごとのレビューを担当する。

- 仕様書: [ui-redesign-spec.md](ui-redesign-spec.md) — トークン(配色・書体・寸法・モーション)、共通コンポーネントのシグネチャ、画面骨格、状態ごとのデッキ表示、文言表、壊してはならない挙動13項目、検証手順
- タスク分割と委譲プロンプト: [ui-redesign-tasks.md](ui-redesign-tasks.md) — T1〜T7、依存関係、モデル配分、タスクごとのレビューチェックリスト

変更の要旨: タブ → サイドバー + 下部固定トランスポートデッキ。デッキが録画状態機械の唯一の顔になり、両ペインで常時見える(DESIGN.md §7 の「ライブラリタブ表示中は failed バナーが見えない」弱点が解消される)。設定はカード群へ。英日混在の文言を日本語へ統一。赤は録画状態とその失敗のみ、操作色はティール、警告は琥珀。

| Constraint | Source | Verify by |
|------------|--------|-----------|
| 情報構成は DESIGN.md §7 を維持(項目を削らない・増やさない) | DESIGN.md | T5/T6 のレビュー |
| Recording/Capture/Contracts/RecordingControls の API 無変更 | user / 既存設計 | `git diff --stat` が View 層のみ |
| 既存テストの変更・削除を禁止、件数は減らさない | constraints.md | `make test` の件数 |
| 警告ゼロを維持 | 既存の運用 | `swift build` の warning 数 |
| 1 worktree 1 writer、実装エージェントは他エージェントを起動しない | behavior.md | 委譲プロンプトの MUST NOT DO |
| macOS 15 より新しい API は `#available` なしで使わない | Package.swift `platforms: [.macOS(.v15)]` | ビルド |

- [x] 仕様・タスク分割 — PR #22
- [x] T1 DesignSystem — PR #23
- [x] T2 SourcePickerView — PR #26
- [x] T3 LibraryView — PR #25
- [x] T4 CropSelectionSheet — PR #24
- [x] T5 MainView 骨格 — PR #27
- [x] T6 TransportDeck — PR #28
- [x] T7 ドキュメント同期 — 本変更（PR番号は作成前）
- 検証証跡: `swift build` 警告0、`make test` 69 tests / 13 suites。
- 実機確認済み: ライブラリ表示中もデッキが見えること、一覧最下部がデッキの下から抜けること、最小幅780で崩れないこと、待機状態の描画、ダーク外観。
- 未検証: ライト外観、録画中・書き出し中・失敗の3状態。予約済み・権限拒否・キーボードのみでの到達はこのリデザイン確認では未検証。

## OSS 配布方式の整備（2026-08-06）

ユーザー質問: 「OSSにしようと思うのですが、配布方法どうするといいですか？」→ 追加で「無料ですませたい」。方針は**無料構成（自己署名 + GitHub Releases）**に決定。実装は Codex へ委譲し、当方はオーケストレーションとレビューを担当する。

- 仕様書: [oss-distribution-spec.md](oss-distribution-spec.md) — 決定事項、実測で確定した前提、人間タスク H1〜H4、実装タスク T1〜T5 の仕様、壊してはならない挙動8項目、Phase B/C の移行差分
- タスク分割と委譲プロンプト: [oss-distribution-tasks.md](oss-distribution-tasks.md) — C1〜C3、依存関係、Codex 委譲プロンプト、タスクごとのレビューチェックリスト

変更の要旨: Apple Developer Program（$99/年）には当面入らない。ad-hoc 署名ではなく自己署名証明書で署名し、画面収録の TCC 許可がアプリ更新後も維持されるようにする。Hardened Runtime と entitlements とタイムスタンプは**いまのうちに入れておき**、将来 notarization へ移行する日の差分をコード非変更の3点だけに閉じる。秘密鍵は CI に置かず、リリースはローカル署名 + `gh release create` とする。

### Constraints

| Constraint | Source | Verify by |
|------------|--------|-----------|
| 無料でおさめる（Developer Program に入らない） | user msg 2026-08-06 | 有料前提の手順が仕様に無いこと |
| `Sources/` と `Tests/` を一切変更しない | 本作業の性質 | `git diff --stat` に両者が出ない |
| 既存テストの件数を減らさない | constraints.md | `make test` の件数（現行 69 tests / 13 suites） |
| 警告ゼロを維持 | 既存の運用 | `swift build -Xswiftc -warnings-as-errors` |
| `make bundle CODESIGN_IDENTITY=-` の ad-hoc 経路を壊さない | README 記載済みの手順 | 実行して成功すること |
| `Resources/Info.plist` をリポジトリ上で書き換えない | テンプレートとして扱う | `git status --short Resources/Info.plist` が空 |
| 自己署名の秘密鍵を CI・リポジトリに置かない | spec §1.1（TCC 許可の継承リスク） | `.github/workflows/` に差分が無いこと |
| 1 worktree 1 writer、実装エージェントは他エージェントを起動しない | behavior.md | 委譲プロンプトの MUST NOT DO |
| Codex への委譲は `gpt-5.6-terra` + effort high | user msg 2026-08-06 | 委譲コマンドの `-m` / `-c` |

### Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| 自己署名証明書の designated requirement は leaf hash 固定で、リビルドに耐える | VERIFIED | `codesign -d -r- CasRec.app` → `identifier "dev.toshi0607.casrec" and certificate leaf = H"…"`（2026-08-06） |
| 自己署名証明書でも `--timestamp` が Apple の TSA に受理される | VERIFIED | 実測 `Timestamp=Aug 6, 2026 at 1:22:32`（2026-08-06） |
| 自己署名証明書でも `--options runtime` が適用される | VERIFIED | 実測 `flags=0x10000(runtime)`（2026-08-06） |
| ad-hoc 署名に `--timestamp` を渡してもエラーにならず無視される（署名フラグの分岐が不要） | VERIFIED | 実測 exit 0 / `flags=0x10002(adhoc,runtime)` / `Signature=adhoc`（2026-08-06） |
| 旧証明書 `CasRec Dev` は 2027-08-03 に失効し、作り直すと leaf hash が変わって全利用者の画面収録許可が飛ぶ | VERIFIED・対処済み | `openssl x509 -noout -dates` → `notAfter=Aug 3 08:16:29 2027 GMT`。公開前に有効期間 3650 日の `CasRec Release`（2036-08-02 まで）を作成し移行した（2026-08-06、spec §3.1） |
| `CasRec Release` で `.app` を署名すると Hardened Runtime・タイムスタンプ・entitlements が同時に成立する | VERIFIED | 実 `.app` で実測（2026-08-06）: `codesign --verify --deep --strict` 成功、`flags=0x10000(runtime)`、`Timestamp=Aug 6, 2026`、`com.apple.security.device.audio-input => true`、DR leaf = `4feed5cfc27c13bd9711823f1edd9a4ee2a96b44` |
| OpenSSL 3.x 既定の PBE / MAC で作った `.p12` は macOS の `security import` が検証できない | VERIFIED | 実測 `MAC verification failed`（2026-08-06）。`-macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES` で解決 |
| Hardened Runtime 有効時、`com.apple.security.device.audio-input` entitlement があればマイク録音が従来どおり動く | UNVERIFIED-ACCEPTED（2026-08-06） | TCC と GUI を伴うため自動検証不可。entitlement が実際に埋め込まれていることは実測済み。緩和策: spec §3 H3 を公開前の必須ゲートとし、通らなければ Hardened Runtime を外して再検討する。外しても notarization 以外の機能は失われない |
| macOS 15 では Gatekeeper にブロックされたアプリの「右クリック → 開く」回避が使えず、システム設定からの「このまま開く」が必要 | UNVERIFIED-ACCEPTED（2026-08-06） | 手元に配布状態（quarantine 付き）の環境が無いため未実測。緩和策: README には `xattr -dr com.apple.quarantine` を代替手順として併記するため、どちらの挙動でも利用者は起動できる |

### タスク

- [x] H1 有効期間 3650 日の自己署名証明書 `CasRec Release` を作成しログインキーチェーンへ登録（2026-08-06）。fingerprint `4feed5cf...6b44`、有効期限 2036-08-02
- [x] H2 秘密鍵を `.p12` でリポジトリ外へバックアップ（toshi0607 が実施、2026-08-06）
- [x] `EXPECTED_LEAF` と spec の fingerprint を新証明書の値へ更新（2026-08-06）
- [x] C1 署名オプション + entitlements（Codex/Luna、2026-08-06）
- [x] C2 バージョン注入 + `make release`（Codex/Terra high、2026-08-06）
- [x] C3 README + RELEASING.md（Codex/Terra high、2026-08-06）
- [x] 外部レビュー指摘3件を解消（2026-08-06、PR #30）
- [x] H3 実機での画面収録とマイク録音の確認（2026-08-06、**合格**）
- [ ] H4 `gh release create` で公開

### 検証証跡

**C3（オーケストレーター再検証、2026-08-06）**: README は追加のみ（削除行 0）で、英語側 `## Install`（Requirements と Build and run の間）と日本語側 `### インストール`（動作環境 と ビルドと起動 の間）が対応。spec §4 T4 の4点（ダウンロード / チェックサム検証 / Gatekeeper 回避 / 未署名の明示）をすべて含み、「右クリック → 開く」は使えない旨も明記。絵文字・バッジ・安全性の断言なし。RELEASING.md は8項目すべてを収録、`tasks/oss-distribution-spec.md` §2.1 へのリンク先も実在を確認。エンドツーエンド: `make release VERSION=0.1.0` → `shasum -c` OK → `ditto -x` 展開後の `.app` が `codesign --verify --deep --strict` 通過、`CFBundleShortVersionString=0.1.0` / `CFBundleVersion=122`。`swift build -Xswiftc -warnings-as-errors` exit 0、`make test` 69 tests / 13 suites。

**C2（オーケストレーター再検証、2026-08-06）**: 12項目すべて通過。(1) `make release`（VERSION 空）エラー終了 (2) `CODESIGN_IDENTITY=-` エラー終了 (3) `make release VERSION=0.0.0-test` 成功 (4) `cd dist && shasum -a 256 -c checksums.txt` → OK (5) zip を `ditto -x` で展開した `.app` が `codesign --verify --deep --strict` 通過、`Authority=CasRec Release` / `flags=0x10000(runtime)` / `Timestamp` 保持 (6) バージョン注入 `CFBundleShortVersionString=0.0.0-test` / `CFBundleVersion=122` (7) `Resources/Info.plist` 無変更 (8) `dist/` は git 無視 (9) **`EXPECTED_LEAF=deadbeef` で release が実際にエラー終了**（ガードが機能） (10) VERSION 未指定の `make bundle` はテンプレート値 `0.1.0` / `2` を維持 (11) `swift build -Xswiftc -warnings-as-errors` exit 0 / `make test` 69 tests / 13 suites (12) `Sources` `Tests` `.github` `Resources/Info.plist` に差分なし。

**C1（オーケストレーター再検証、2026-08-06）**: `make bundle` 成功。`Authority=CasRec Release` / `flags=0x10000(runtime)` / `Timestamp=Aug 6, 2026 at 1:22:32` の3点を確認。DR = `identifier "dev.toshi0607.casrec" and certificate leaf = H"4feed5cfc27c13bd9711823f1edd9a4ee2a96b44"`。埋め込み entitlements は `com.apple.security.device.audio-input => true` の1件のみ。`codesign --verify --deep --strict` 通過。`make bundle CODESIGN_IDENTITY=-` 成功（`flags=0x10002(adhoc,runtime)` / `Signature=adhoc`）。`swift build -Xswiftc -warnings-as-errors` exit 0。`make test` 69 tests / 13 suites。`Sources` `Tests` `Resources/Info.plist` `.github` に差分なし。

### Notes

- 当初「Developer ID が無いと画面収録の許可が維持できない」と説明したが、実測により**自己署名証明書でも維持できる**ことが判明したため訂正した。ad-hoc 署名だけが毎ビルド許可を失う。この差が無料構成を成立させている。
- H1 は Keychain Access の証明書アシスタント（GUI）ではなく CLI で作成した。有効期間と拡張鍵用途を明示でき、手順を RELEASING.md に転記できるため。`security import` には OpenSSL 3.x 既定ではない PBE / MAC アルゴリズムの指定が要る（spec §3.1）。
- 開発用の `CasRec Dev` は退役し、開発ビルドも配布ビルドも `CasRec Release` に統一した。識別子が1つなら DR も1つで、ローカル確認がそのまま配布物の検証になる。**副作用として開発機の画面収録許可が一度だけ失効する** — lessons.md 2026-08-03 の手順どおり `tccutil reset ScreenCapture dev.toshi0607.casrec` で掃除してから再許可する。公開前の一度きりで利用者には影響しない。
- Homebrew Cask は Phase B として今回のスコープから外した。tap リポジトリの新規作成が必要で、Releases の成立が先。
- GitHub Actions のリリース用ワークフローは**作らない**。自己署名の秘密鍵を CI に置くと、同じ証明書・同じ bundle id で署名された偽アプリが利用者の画面収録許可をダイアログなしで引き継げてしまうため（spec §1.1）。
- **C1 の委譲中に Codex が `tasks/todo.md` を作業ツリーの HEAD 状態へ戻し、本節の未コミット追記が消失した**（2026-08-06、復元済み）。未追跡の spec / tasks 文書は無事だった。以後、委譲前に追跡ファイルの編集をコミットするか、委譲中は追跡ファイルを編集しない。lessons.md に記録。
- C2 の委譲中に Codex(Terra) が `ERROR: Selected model is at capacity` で exit 1。**実装ファイルは書き込み済みだったが検証は一切走っていなかった**（`dist/` が生成されていないことで判別）。オーケストレーターが12項目を代わりに実行して全通過を確認した。エージェントの異常終了時は「書き込みの有無」と「検証の有無」を別々に確かめること。
- C2 の成果物に対しレビューで2点だけオーケストレーターが直接修正した（逸脱記録）: (a) `make release` が `dist/checksums.txt` 自身の SHA256 を表示していた無意味な行を、成果物パスと `cat dist/checksums.txt` に置き換え (b) `clean` の削除対象に `dist` を追加（古いリリース成果物が残って誤アップロードされる事故を防ぐ。spec §4 T3 で「追加は可」としていた）。いずれも1〜2行で、再委譲のコストに見合わないと判断した。
- C3 は Codex(Terra high) が完走（exit 0）。ただし Codex のサンドボックスでは module cache への書き込みが不可で `swift build` が manifest 段階で失敗し、証明書取得もできなかったため、**エージェント側の検証は実質ゼロ**。品質ゲートはすべてオーケストレーターが実行した。
- 残る品質上の小さな指摘（対応不要と判断、記録のみ）: RELEASING.md §5 の実機確認が「ビルドした `CasRec.app`」を対象としており、利用者が実際に受け取る「zip を展開した `.app`」ではない。quarantine の有無が異なるだけで録画機能の確認としては等価なため、H3 の実施時に zip 展開版で行えばよい。

### PR #30 レビュー対応（2026-08-06）

外部レビューで3件の指摘。いずれも再現手順で確認したうえで修正した。

- **P1（必須・実害あり）**: `bundle` が既存の `CasRec.app` を削除せず3ファイルだけ上書きしていたため、以前のビルド由来のファイルがバンドル内に残り続けた。**実測で確認**: `Contents/Resources/OldIcon.icns` を置いて再 `make bundle` すると、異物が `codesign --force` で `CodeResources` に封入され（出現回数2）、`codesign --verify --deep --strict` は **valid on disk / satisfies its DR** を返し、そのまま release ZIP に混入した。検知手段が無い。修正: `bundle` の先頭で `rm -rf "$(APP_BUNDLE)"`。修正後は同じ手順で異物が消え、`CodeResources` 出現回数0、ZIP 混入なしを確認。
  - 補足: 最初 `Contents/Frameworks/` に偽 dylib を置いて試したが、これは `codesign` 自体が「code object is not signed at all」で失敗する特殊ケースで、指摘の再現にはならなかった。`Resources/` の平文ファイルが現実的かつ危険なケースである。
- **P2（必須）**: README の英日「ビルドと起動」が既定署名IDを `CasRec Dev` と説明したままだった（英語 L66 / 日本語 L177）。`CasRec Release` に更新し、「メンテナのローカル自己署名証明書」という説明に揃えた。
- **P2（推奨）**: spec §3 の H2 が「未了」、§3.1 末尾が「単一障害点」のままで、todo.md の完了記録と食い違っていた。spec §3 / §3.1 と tasks 文書の依存グラフ・注記を完了状態へ同期した。

修正後の回帰: `make release VERSION=0.0.0-p1test` 成功・`shasum -c` OK、ad-hoc フォールバック維持（`flags=0x10002(adhoc,runtime)`）、ガード3種すべて非0終了、`swift build -Xswiftc -warnings-as-errors` exit 0、`make test` 69 tests / 13 suites。

### H3 実機検証（2026-08-06、合格）

`make release VERSION=0.1.0-rc0` が生成した ZIP を `ditto -x` で展開した**実際の配布物**を対象に実施。開発用ビルドではない。

事前に `tccutil reset ScreenCapture / Microphone dev.toshi0607.casrec` で旧署名のレコードを掃除し、システム設定から画面収録を再許可（ユーザー操作）。マイクは録画開始時に許可済み。

| 検証項目 | 結果 |
|---|---|
| 配布物の署名 | `codesign --verify --deep --strict` 通過、`Authority=CasRec Release` |
| Hardened Runtime | `flags=0x10000(runtime)` |
| タイムスタンプ | `Aug 6, 2026 at 20:29:37` |
| 埋め込み entitlements | `com.apple.security.device.audio-input => true` |
| 起動・UI | 正常。ソース一覧・サムネイル表示・トグル操作すべて動作 |
| 録画 | 画面全体 38.2 秒、drop 0、finalize 成功（サイドカー残骸なし） |
| トラック構成 | HEVC 1 + AAC 2（アプリ音声・マイク） |
| 映像 | 2940×1912（1470×956 の Retina 2x）、bt709、1112 フレーム、全フレーム走査でデコードエラーなし、先頭・末尾ともシーク可 |
| 映像の内容 | 末尾フレームを目視。デスクトップ全体がウィジェット含め正しく記録され、色も自然 |
| **マイク音声** | **stream 1: 3,317,632 samples / mean -35.7 dB / max -9.3 dB** |
| アプリ音声 | stream 0: 3,659,648 samples / mean -26.6 dB / max -3.7 dB |

**Hardened Runtime 下でマイク entitlement が効いていることの実証**: マイクトラックに 331 万サンプル・非無音の実信号が記録された。entitlement が欠けていればサンプル 0 件になる。アプリ音声より約 9 dB 低く、長さも 3.5 秒短い（マイク初期化の分）という、音響経由で拾った実マイク入力に固有の特徴も一致している。

これで公開前の必須ゲートはすべて通過した。

### Notes 追記

- H3 実施中、私の画面操作ツール（computer-use）のスクリーンショット・フィルタリングが**コンポジタ側で他アプリのウィンドウを隠すため、CasRec の `SCShareableContent` からもそれらが見えなくなり**、ウィンドウ一覧が「録画できるウィンドウがありません」になる現象が起きた。CasRec の不具合ではなく検証環境の副作用。「画面全体」に切り替えることで回避した。次回同じ検証をするときはウィンドウ指定を避けるか、対象アプリを許可リストに入れる。

## Phase B — Homebrew Cask（2026-08-06、完了）

ユーザー指示: 「Codex使ってphase Bやってください」。仕様は [oss-distribution-spec.md](oss-distribution-spec.md) §7、実装は Codex(Terra high) へ委譲、オーケストレーションとレビューは当方。

### 事実の訂正

Phase A の説明で「cask なら `brew install --cask --no-quarantine` で Gatekeeper の手順が消える」と述べたが、**誤りだった**。`--no-quarantine` は Homebrew で非推奨化のうえ削除済み（`brew --repository` の git log に `ffe954753b` / `ba25213c81`）。現行 6.0.14 の help にも存在しない。cask 経由でも quarantine 属性は付き、初回の Gatekeeper 手順は消えない（実測: `xattr -p com.apple.quarantine /Applications/CasRec.app` → `0381;6a7478aa;;DD3C243F-...`）。

代わりに、調査の過程で**より価値のある性質**が確定した。`brew upgrade --cask` は `quarantine_release_decision` が `:release` を返すとき Gatekeeper 承認を引き継ぐ。その条件は「利用者が旧版を承認済み」かつ「署名 identity が不変」。CasRec は `CasRec Release` 証明書で identity を固定してあるため条件を満たす。**Phase A の安定 DR の決定がここで直接効く。**

### 成果物

- tap リポジトリ `toshi0607/homebrew-tap`（public、新規作成）に `Casks/casrec.rb` と README
- `scripts/update-cask.sh` — `dist/checksums.txt` から SHA256 を読み、cask の version と sha256 の2行だけを書き換える
- RELEASING.md §7、README 英日のインストール節

### 検証証跡（オーケストレーター実測）

| 項目 | 結果 |
|---|---|
| クリーン状態からの一行インストール | `brew install --cask toshi0607/tap/casrec` 成功（untap + trust.json 無しの状態から） |
| Tap Trust | CasRec には trust 手順が不要。警告は利用者の既存の他 tap に対するもの |
| チェックサム自動照合 | `✔︎ Cask casrec (0.1.0)` |
| インストール後の署名 | `codesign --verify --deep --strict` 通過、`Authority=CasRec Release`、`flags=0x10000(runtime)`、Timestamp 保持 |
| quarantine 属性 | **付く**（Gatekeeper は適用される。上記の訂正を実物で確認） |
| `depends_on macos: ">= :sequoia"` | 非推奨警告が出たため `:sequoia` へ修正。`brew info` の Requirements は `macOS >= 15` のまま |
| update-cask.sh 異常系 | 引数なし → usage、`dist/` 不在 → `make release` を促すエラー |
| update-cask.sh 正常系 | `make release VERSION=0.2.0` の SHA を正しく反映、変更は2行のみ、差分表示と audit 案内あり（検証後 tap は 0.1.0 へ復帰） |
| 品質ゲート | `swift build -Xswiftc -warnings-as-errors` exit 0、`make test` 69 tests / 13 suites |

### Notes

- 仕様に書いた `depends_on macos: ">= :sequoia"` は非推奨形式だった（当方のミス）。Codex は仕様どおり書いたので責はない。実測で検出し修正した。
- Codex(Terra high) は C4 / C5 とも完走し、今回は他者の未コミット変更の巻き戻しも起きなかった（委譲プロンプトに禁止を明記した効果と思われる）。

### Phase B レビュー対応（2026-08-06）

指摘1件（P1）。**問題は実在したが、提示された修正案は現行 Homebrew では成立しなかった**ため、別の方法で直した。

- **指摘**: `update-cask.sh` は `../homebrew-tap` を書き換えるのに、案内する audit コマンドは固定トークン `toshi0607/tap/casrec` であり、Homebrew 管理下の**更新前の cask** を audit して成功しうる。
- **再現**: 別クローンだけを version 0.2.0 / sha256 全ゼロに書き換えた状態で `brew audit --cask toshi0607/tap/casrec` が exit 0。指摘のとおり。
- **修正案が使えない理由**: `brew audit --cask <path>` は `Error: Calling 'brew audit [path ...]' is disabled! Use 'brew audit [name ...]' instead.` で拒否される。パス指定は無効化済み。
- **採用した修正**: 編集先の既定を Homebrew 管理下のチェックアウト（`$(brew --repository)/Library/Taps/toshi0607/homebrew-tap`）にして、audit 対象と編集対象を構造的に一致させた。ここは push remote 付きの通常の git クローンなので commit・push 元にもなる。`CASREC_TAP` で別クローンを指定した場合は「トークン audit は別のファイルを読む」と警告し、push → `brew update` → audit の順を案内する。
- **修正後の実測**: 既定パスで更新後の `brew audit --cask --online toshi0607/tap/casrec` が、存在しない v0.2.0 の URL に対し `curl: (56) ... 404` / `Error: 3 problems in 1 cask detected.` を返した。audit が編集後の内容を読んでいる。`CASREC_TAP` 指定時は警告分岐が出ることも確認。
- 途中、警告文に入れたアポストロフィで `bash -n` が構文エラーになった（当方のミス）。文言を変更して解消。
- 検証で触れた両チェックアウトは 0.1.0 へ復帰済み。品質ゲート: `swift build -Xswiftc -warnings-as-errors` exit 0、`make test` 69 tests / 13 suites。

## Codex Security 指摘修正（2026-08-09）

- [x] 5件の検証済み指摘と最新 `main` の到達経路を再確認する。
- [x] 利用案内・ライセンス・READMEが最新 `main` に含まれることを確認し、PRをセキュリティ修正だけに限定する。
- [x] owner-bound対象再解決、ライブラリ解析上限、ffmpeg境界・監督、Hardened Runtime検証を移植する。
- [x] 全テスト、警告厳格build、bundle、署名、変異検証を実行する。
- [x] 独立レビューを完了し、production/test blocker がないことを確認する。
- [ ] コミット・pushし、ドラフトPRを作成する。

詳細: [security-fixes/task_plan.md](security-fixes/task_plan.md)
