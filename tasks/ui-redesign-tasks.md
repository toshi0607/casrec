# CasRec UI リデザイン — タスク分割と委譲プロンプト

仕様の真実は [ui-redesign-spec.md](ui-redesign-spec.md)。この文書はタスクの順序、各実装エージェントへ渡すプロンプト、レビュー担当(オーケストレーター)のチェックリストを持つ。

## 依存関係と実行順

```
T1 DesignSystem  ← 全タスクの前提。単独で先に完了させる
      │
      ├─ T2 SourcePickerView  ┐
      ├─ T3 LibraryView       ├ 並行可(それぞれ別worktree、担当ファイルが重ならない)
      ├─ T4 CropSelectionSheet┘
      │
      └─ T5 MainView 骨格     ← 直列(MainView.swift の唯一の書き手)
              │
              └─ T6 TransportDeck ← 直列(MainView.swift を再度触る)
                      │
                      └─ T7 ドキュメント同期
```

- **1 worktree 1 writer**。並行させるときは T2/T3/T4 を各自の worktree に分け、オーケストレーターは稼働中に同じ worktree へ書き込まない。
- 並行が面倒なら T1→T2→T3→T4→T5→T6→T7 の直列でよい。結果は同じ。
- 各タスクの完了後、次を出す前にレビューする(下のチェックリスト)。**レビュー未通過のまま次へ進めない。**

## モデル配分

| タスク | 性質 | モデル |
|--------|------|--------|
| T1 DesignSystem | 仕様が確定した機械的な新規ファイル | `sonnet` |
| T2 SourcePickerView | 小さな見た目の作り替え | `haiku` |
| T3 LibraryView | 中規模の見た目の作り替え | `sonnet` |
| T4 CropSelectionSheet | 小さな見た目の作り替え | `haiku` |
| T5 MainView 骨格 | 構造変更 + 挙動維持の責任が重い | `opus` |
| T6 TransportDeck | 設計の主役。造形と状態表現の判断が要る | `opus` |
| T7 ドキュメント同期 | 文書 | `tech-docs-writer` / `sonnet` |

---

# T1 — DesignSystem.swift

```
1. TASK
   CasRec に共通デザイントークンとUIコンポーネントを1ファイルで新設する。
   新規作成するのは Sources/CasRec/UI/DesignSystem.swift のみ。既存ファイルは1行も変更しない。

2. EXPECTED OUTCOME
   - Sources/CasRec/UI/DesignSystem.swift が存在し、tasks/ui-redesign-spec.md §2 と §3 に書かれた
     トークンとコンポーネントを、そこに記載されたシグネチャどおりに公開している。
   - `swift build` が exit 0、警告0。
   - `make test` の件数が実行前から減っていない(件数を報告に書く)。
   - 既存ファイルの差分がゼロであること(`git status` の出力を報告に貼る)。

3. REQUIRED SKILLS
   なし(仕様書に従うだけ)。

4. REQUIRED TOOLS
   Read, Write, Bash(swift build / make test / git status のみ)

5. MUST DO
   - 最初に tasks/ui-redesign-spec.md を全文読む。§2(トークン)と §3(コンポーネント)が実装対象。
   - 色は §2.1 の dynamicColor ヘルパーをそのまま使い、クロージャの外で NSColor を作らない
     (Swift 6 の Sendable 制約に触れるため。数値タプルだけをキャプチャする)。
   - Theme.signal / Theme.accent / Theme.caution / Theme.cardFill / Theme.hairline と
     Theme.Metric の各定数を、仕様書の数値そのままで定義する。
   - Font.machine(_:weight:) と View の cardTitleStyle() / fieldLabelStyle() / metaStyle() を定義する。
   - SectionCard(アクセサリ有り/無しの2イニシャライザ)、NoticeBanner(extra 有り/無しの2イニシャライザ)、
     FieldRow を仕様書のシグネチャどおりに実装する。
   - このファイルは他のViewからまだ使われない。単体でビルドが通ることだけを確認する。
   - コメントは「なぜそうしたか」だけ書く。何をしているかの説明コメントは書かない。

6. MUST NOT DO
   - 他のエージェントを起動しない。自分のツールだけで実装する。
   - Sources/CasRec/UI/DesignSystem.swift 以外のファイルを作成・変更・削除しない。
   - 仕様書にない色・寸法・コンポーネントを足さない。
   - macOS 15 より新しいAPIを #available なしで使わない(Package.swift の platforms は .macOS(.v15))。
   - テストを変更・追加・削除しない。
   - git commit / git push をしない。

7. CONTEXT
   - リポジトリ: CasRec(個人用 macOS スクリーンレコーダー、SwiftUI + SwiftPM、Xcode なし)。
   - ビルドは `swift build`、テストは `make test`(`swift test` は使えない。Makefile のコメント参照)。
   - `swift build` は親ディレクトリを遡って Package.swift を拾うため、ビルドログに
     Sources/CasRec/ のファイル名が出ていることを確認して偽陽性でないことを示すこと。
   - 既存のUIコードは Sources/CasRec/UI/ と Sources/CasRec/Library/LibraryView.swift にある。
     現状は Color.blue / Color.red / .cornerRadius の直書きだが、このタスクでは直さない。
```

**レビューチェック(T1)**
- [ ] 仕様書 §2.1 の16進値と一致するか(6色×2外観)
- [ ] `dynamicColor` のクロージャが `NSColor` をキャプチャしていない
- [ ] `Theme.Metric` の8定数が仕様どおり
- [ ] `SectionCard` / `NoticeBanner` の2イニシャライザが両方ある
- [ ] `swift build` 警告0、`git status` が新規1ファイルのみ
- [ ] 余計な抽象(未使用のスタイル、Enum、プロトコル)が足されていない

---

# T2 — SourcePickerView

```
1. TASK
   Sources/CasRec/UI/SourcePickerView.swift を、tasks/ui-redesign-spec.md §2 のトークンと
   §6.2 の指定に沿って作り替える。ファイルはこの1つだけ変更する。

2. EXPECTED OUTCOME
   - サムネイルが 132×82 / 角丸8 になり、選択中の項目が Theme.accent の2ptリングと
     20%のハロー3ptで示される。
   - View 内の見出し "Sources" が削除されている(カード見出し「対象」に統合されるため)。
   - 色・寸法の直書き(Color.blue、Color.gray、.cornerRadius)が残っていない。
   - `swift build` exit 0 / 警告0、`make test` の件数が減っていない。
   - 変更ファイルは SourcePickerView.swift のみ(`git status` を報告に貼る)。

3. REQUIRED SKILLS
   なし。

4. REQUIRED TOOLS
   Read, Edit, Write, Bash(swift build / make test / git status のみ)

5. MUST DO
   - 最初に tasks/ui-redesign-spec.md の §2(トークン)、§6.2(対象カード)、§9(品質の下限)を読む。
   - 公開シグネチャ `SourcePickerView(sources:selectedSourceId:)` を変えない。呼び出し側は別タスクが直す。
   - サムネイル画像は「固定フレーム → clipped → clipShape」の順で切り、はみ出しを起こさない。
   - サムネイルが無い項目のプレースホルダ(SF Symbol)は残す。色は .secondary。
   - ラベルは選択中のみ .primary + medium、非選択は .secondary。11pt、2行まで。
   - 各項目に .accessibilityLabel(表示名)と .accessibilityAddTraits(.isButton) を付ける。
   - 選択中の項目に .help(source.title) を付けて、切り詰められた完全なタイトルを読めるようにする。

6. MUST NOT DO
   - 他のエージェントを起動しない。
   - SourcePickerView.swift 以外を変更しない(DesignSystem.swift も読むだけ)。
   - onTapGesture 以外の選択手段を足したり、選択ロジックを変えたりしない。
   - アニメーションを足さない(仕様書 §2.4 で許可されたもの以外は禁止)。
   - テストを変更しない。git commit / push をしない。

7. CONTEXT
   - Theme / Font.machine / 各 style モディファイアは Sources/CasRec/UI/DesignSystem.swift にある(T1 で作成済み)。
   - CaptureSource は id / kind / title / appName / thumbnail(CGImage?) を持つ。表示名は appName ?? title。
   - ビルドは `swift build`、テストは `make test`。
```

**レビューチェック(T2)**
- [ ] `Color.blue` / `Color.gray` / `.cornerRadius` が残っていない
- [ ] 画像のクリップ順序が正しく、`.scaledToFill()` のはみ出しが無い
- [ ] 選択リングが `Theme.accent`、寸法が仕様どおり
- [ ] シグネチャ不変、選択ロジック不変
- [ ] 読み上げラベルあり

---

# T3 — LibraryView

```
1. TASK
   Sources/CasRec/Library/LibraryView.swift の表示層を、tasks/ui-redesign-spec.md §7 に沿って
   作り替える。ジョブキュー・削除・QuickLook まわりのロジックは1行も変えない。

2. EXPECTED OUTCOME
   - ペイン内の見出し行(Text("ライブラリ") + 更新ボタン)が削除され、更新は .toolbar の
     ボタン(.accessibilityLabel("一覧を更新") と .help("一覧を更新"))になっている。
   - ffmpeg 不在の案内が NoticeBanner(.info, message:) になっている。
   - 行のサムネイルが 112×63 / 角丸6、ファイル名が .lineLimit(1) + .truncationMode(.middle)、
     メタ行の「時間」と「サイズ」が Font.machine(11) になっている。
   - 未finalize バッジが Theme.caution.opacity(0.16) のカプセルになっている。
   - `swift build` exit 0 / 警告0、`make test` の件数が減っていない。
   - 変更ファイルは LibraryView.swift のみ。

3. REQUIRED SKILLS
   なし。

4. REQUIRED TOOLS
   Read, Edit, Bash(swift build / make test / git status のみ)

5. MUST DO
   - 最初に tasks/ui-redesign-spec.md の §2、§7、§9、§10 を読む。
   - 公開シグネチャ LibraryView(directory:refreshToken:allowsDeletion:) を変えない。
   - 次の挙動を維持する(完了報告で1つずつ根拠付きで述べる):
     * allowsDeletion が false のとき「ゴミ箱に移動」が無効
     * ffmpeg 不在時に「GIF変換」「修復を試す」が無効で、.help に brew install ffmpeg の案内が出る
     * 行のダブルクリックで QuickLook が開く
     * ジョブ完了時の再読み込みと失敗時のエラーアラート
     * 削除確認アラートと、サイドカーファイルの同時ゴミ箱移動
   - 空状態の ContentUnavailableView は文言も含めてそのまま残す。
   - 色・寸法は DesignSystem.swift のトークンから取る。

6. MUST NOT DO
   - 他のエージェントを起動しない。
   - LibraryView.swift 以外を変更しない。
   - PostProcessQueue / LibraryScanner / QuickLookPreviewer のロジックに触らない。
   - List を LazyVStack 等に置き換えない(選択・スクロールの挙動が変わるため)。
   - テストを変更しない。git commit / push をしない。

7. CONTEXT
   - Theme / NoticeBanner / Font.machine は Sources/CasRec/UI/DesignSystem.swift にある。
   - LibraryEntry は fileName / dateText / durationText / fileSizeText / isGIF / isUnfinalized / url を持つ。
   - このビューは NavigationSplitView の詳細ペインに置かれる(別タスク)。.toolbar はそこで機能する。
   - ビルドは `swift build`、テストは `make test`。
```

**レビューチェック(T3)**
- [ ] 更新ボタンが toolbar に移り、ペイン内の重複見出しが消えた
- [ ] 維持リスト5項目が実際にコードで維持されている(該当行を確認)
- [ ] メタ行の等幅化が「時間・サイズ」に限定され、日本語まで等幅になっていない
- [ ] `Color.orange` / `Color.secondary.opacity` 等の直書きがトークンに置き換わっている
- [ ] `swift build` 警告0

---

# T4 — CropSelectionSheet

```
1. TASK
   Sources/CasRec/UI/CropSelectionSheet.swift の見た目を、tasks/ui-redesign-spec.md §2 の
   トークンに揃える。座標変換とジェスチャのロジックは1行も変えない。

2. EXPECTED OUTCOME
   - 見出し・補足・寸法表示の書体が仕様のスケールに従っている(寸法値は Font.machine(11))。
   - 選択矩形の枠線が Theme.accent、外側の減光が仕様の不透明度に揃っている。
   - `swift build` exit 0 / 警告0、`make test` の件数が減っていない。
   - 変更ファイルは CropSelectionSheet.swift のみ。

3. REQUIRED SKILLS
   なし。

4. REQUIRED TOOLS
   Read, Edit, Bash(swift build / make test / git status のみ)

5. MUST DO
   - 最初に tasks/ui-redesign-spec.md の §2 と §9 を読む。
   - 文言 "領域: 1714×946" を "領域 1714×946" に変える(コロンを削る)。他の文言は変えない。
   - ボタンの並び(クリア / キャンセル / 決定)、キーボードショートカット、無効化条件を変えない。
   - CropPreviewCanvas の Color.black(写真の下敷き)はそのまま残す。
   - CropGeometry の呼び出し、coordinateSpace の指定、DragGesture の設定に触らない。

6. MUST NOT DO
   - 他のエージェントを起動しない。
   - CropSelectionSheet.swift 以外を変更しない。
   - シートのサイズ制約(minWidth: 640, minHeight: 360, maxHeight: 620)を変えない。
   - テストを変更しない。git commit / push をしない。
   - CropGeometryTests が守っている座標計算に影響する変更をしない。

7. CONTEXT
   - この画面は過去に座標ずれのバグ(PR #17)を出しており、ジェスチャまわりは触ると危険。
     見た目だけを変えること。
   - Theme / Font.machine は Sources/CasRec/UI/DesignSystem.swift にある。
   - ビルドは `swift build`、テストは `make test`。
```

**レビューチェック(T4)**
- [ ] `CropGeometry` 呼び出し・`coordinateSpace`・`DragGesture` の差分がゼロ
- [ ] `make test` の CropGeometryTests が全パス
- [ ] 変更が書体・色・文言1箇所に留まっている

---

# T5 — MainView の骨格

```
1. TASK
   Sources/CasRec/UI/MainView.swift を、tasks/ui-redesign-spec.md §4 と §6 の骨格に作り替える。
   タブを NavigationSplitView のサイドバーに置き換え、設定を SectionCard 群に整理し、
   文言を §8 の表どおりに日本語へ統一する。
   このタスクでは画面下部の録画コントロールと StatusView は「今のまま」残す(次タスクで置き換える)。

2. EXPECTED OUTCOME
   - ルートが NavigationSplitView で、サイドバーに「録画」「ライブラリ」の2項目がある。
   - 録画ペインが 通知 → 対象 → 音声 → 画質と上限 → 保存先 → 予約 の SectionCard 群になっている。
   - 5種類あったバナー実装がすべて NoticeBanner に統一されている。
   - §8 の文言表の変更がすべて適用されている(下部の録画コントロール内の文言を除く)。
   - ルートに .tint(Theme.accent)、.navigationTitle("CasRec")、各ペインに .navigationSubtitle。
   - ウィンドウ最小サイズが 780×580、コンテンツが最大幅760で中央寄せ。
   - `swift build` exit 0 / 警告0、`make test` の件数が減っていない。
   - 変更ファイルは MainView.swift のみ。

3. REQUIRED SKILLS
   frontend-design

4. REQUIRED TOOLS
   Read, Edit, Write, Bash(swift build / make test / git status のみ)

5. MUST DO
   - 最初に tasks/ui-redesign-spec.md を全文読む。特に §10「壊してはならない挙動」の13項目。
   - §10 の13項目のうち、このファイルに属する #1〜#9, #12, #13 を維持する。
     完了報告で、各項目について「維持した根拠(コードのどの行か)」を1行ずつ書く。
   - @State のプロパティ、init、computed property(isRecording / isTransitioning / isPollingSources /
     visibleSources / selectedSource)は原則そのまま残す。サイドバー選択用の @State だけ追加してよい。
   - .task(id: isPollingSources)、.onChange(of: currentState)、.sheet(item: $cropPreview)、
     .alert("領域選択エラー", ...) はルート階層に残す(ペインを切り替えても効くこと)。
   - LibraryView の呼び出し引数(directory / refreshToken / allowsDeletion)を変えない。
   - 色・寸法・書体は DesignSystem.swift のトークンからのみ取る。
   - 「画質と上限」は Grid の2列2行にする。4つ横並びは日本語ラベルで崩れるため使わない。

6. MUST NOT DO
   - 他のエージェントを起動しない。
   - MainView.swift 以外のファイルを変更・削除しない(StatusView.swift も残す)。
   - RecordingControls / RecordingSessionControlling / CaptureServicing の API を変えない。
     呼び出し方も変えない(startManually / stop / acknowledgeFailure / scheduleRecording /
     cancelScheduledRecording / saveOutputDirectory / selectSource)。
   - DESIGN.md §7 にある項目を削らない、増やさない(モード切替・対象一覧・音声2つ・
     コーデック/解像度/FPS/上限・保存先・予約・録画開始/停止・録画中の計測値)。
   - 仕様書 §2.4 で許可されたもの以外のアニメーションを足さない。
   - TabView を残さない。逆に、サイドバー以外のナビゲーション(トグル、セグメント等)にもしない。
   - テストを変更しない。git commit / push をしない。

7. CONTEXT
   - 現状の MainView.swift は 625行、TabView + ScrollView の平積みで、バナーが5箇所に別実装されている。
   - Theme / SectionCard / NoticeBanner / FieldRow / Font.machine は
     Sources/CasRec/UI/DesignSystem.swift にある(T1 で作成済み)。
   - SourcePickerView は見出しを持たなくなっている(T2 で削除済み)。カード見出し「対象」がその役目を負う。
   - macOS 15 より新しいAPIを #available なしで使わない。
   - ビルドは `swift build`、テストは `make test`。`swift build` の偽陽性回避のため、
     ビルドログに Sources/CasRec/ のファイル名が出ていることを確認して報告する。
```

**レビューチェック(T5)**
- [ ] §10 の #1〜#9, #12, #13 が実際に維持されている(報告の根拠行を1つずつ確認)
- [ ] `isPollingSources` の `.task(id:)` がペイン切り替えで破棄されない位置にある
- [ ] `syncSelection()` が「列挙更新時」と「モード変更時」の両方から呼ばれている
- [ ] crop シートの `cropPreviewSourceID == selectedSourceId` ガードが2箇所とも残っている
- [ ] バナーが5箇所とも `NoticeBanner` に統一され、独自実装が残っていない
- [ ] 文言表 §8 の未適用が無い(英語文字列の grep で確認)
- [ ] `swift build` 警告0、`git status` が MainView.swift のみ

---

# T6 — TransportDeck(設計の主役)

```
1. TASK
   Sources/CasRec/UI/TransportDeck.swift を新規作成し、MainView の下部にある録画コントロールと
   StatusView をこれに置き換える。tasks/ui-redesign-spec.md §5 が完全な仕様。

2. EXPECTED OUTCOME
   - Sources/CasRec/UI/TransportDeck.swift が存在し、仕様書 §5 のシグネチャで公開されている。
   - MainView が .safeAreaInset(edge: .bottom, spacing: 0) でデッキを置き、
     録画ペインとライブラリペインの両方で見える。
   - 旧 recordingControlSection と StatusView の呼び出しが MainView から消え、
     Sources/CasRec/UI/StatusView.swift が削除されている。
   - idle / preparing / recording / finishing / failed の5状態が仕様書 §5.1 の表どおりに描き分けられる。
   - 録画中の上限進捗がデッキ上端の2ptトラックに出る。
   - 空き容量警告とフレーム停止警告がデッキ内の警告ストリップに出る。
   - `swift build` exit 0 / 警告0、`make test` の件数が減っていない。
   - 変更は TransportDeck.swift(新規)、MainView.swift(差し替え)、StatusView.swift(削除)の3つのみ。

3. REQUIRED SKILLS
   frontend-design

4. REQUIRED TOOLS
   Read, Write, Edit, Bash(swift build / make test / git status / git rm のみ)

5. MUST DO
   - 最初に tasks/ui-redesign-spec.md を全文読む。§5 が実装対象、§10 が守る挙動。
   - タイムコードは TimelineView(.periodic(from: .now, by: 1)) で更新する。
     RecordingProgress の更新に依存させない(フレーム停止中も時計は進むこと)。
   - 上限進捗の割合は min(1, 経過秒 / maximumDuration)。maximumDuration が nil のときはトラックを塗らない。
   - 明滅は @Environment(\.accessibilityReduceMotion) が true のとき止める。
   - 録画ボタンに .help と .accessibilityLabel を付ける。.keyboardShortcut は付けない
     (Carbon のグローバルホットキー ⌥⌘R と二重発火するため)。
   - §10 の #10(failed は acknowledgeFailure を呼ばないと idle に戻らない)、#11(上限表示は
     activeRecordingMaximumDuration)、#13(開始は startManually、停止は session.stop)を維持する。
     完了報告で3項目それぞれの根拠行を書く。
   - StatusView.swift の削除は `git rm` で行い、他から参照されていないことを grep で確認してから消す。

6. MUST NOT DO
   - 他のエージェントを起動しない。
   - 上記3ファイル以外を変更しない。
   - RecordingState / RecordingProgress / RecordingControls の定義を変えない。
   - デッキに新しい機能(一時停止、音量、設定へのショートカット等)を足さない。表示だけを担う。
   - 仕様書 §2.4 以外のアニメーション、グラデーション、影(録画中のボタンの影を除く)を足さない。
   - テストを変更しない。git commit / push をしない。

7. CONTEXT
   - この画面の設計上の主役。大胆さはここ1箇所に集約し、周囲のカードは静かなままにする。
   - RecordingState は idle / preparing / recording(RecordingProgress) / finishing / failed(message:)。
     RecordingProgress は startedAt / bytesWritten / droppedFrames / audioAppendFailures /
     isStalled / diskWarning を持つ(Sources/CasRec/Core/Contracts.swift)。
   - サイズの整形は削除する StatusView.swift の実装(1GB以上は GB、それ未満は MB)をそのまま移植する。
   - 上限の表示ラベルは RecordingDurationLimit.hudLabel(00:30 / 01:00 / 02:00 / 03:00)。
   - Theme / NoticeBanner / Font.machine は Sources/CasRec/UI/DesignSystem.swift にある。
   - macOS 15 より新しいAPIを #available なしで使わない。
   - ビルドは `swift build`、テストは `make test`。
```

**レビューチェック(T6)**
- [ ] 5状態すべてが仕様書 §5.1 の表と一致(コードを状態ごとに追う)
- [ ] タイムコードが `TimelineView` 駆動で、progress 更新に依存していない
- [ ] 上限が nil のときにトラックもバッジも出ない
- [ ] `accessibilityReduceMotion` の分岐がある
- [ ] `.keyboardShortcut` が付いていない
- [ ] `StatusView.swift` が削除され、参照が残っていない(grep)
- [ ] failed からの復帰が `acknowledgeFailure()` を通る
- [ ] `swift build` 警告0、変更が3ファイルのみ
- [ ] **実機**: ライト/ダーク、幅780と1600、idle/recording/failed の見え方(レビュー担当が `make bundle` して確認)

---

# T7 — ドキュメント同期

```
1. TASK
   UI リデザインの結果に合わせて DESIGN.md §7 と tasks/todo.md を更新する。コードは1行も変えない。

2. EXPECTED OUTCOME
   - DESIGN.md §7 のワイヤフレームと説明文が、実装後の画面(サイドバー + カード + 下部デッキ)と一致している。
   - 「録画失敗は録画タブ内の failed バナーに一本化する。ライブラリタブ表示中はバナーが見えないため…」の
     記述が、デッキが常時見える新構成に合わせて更新されている。
   - tasks/todo.md に「### モダンUIリデザイン(2026-08-05)」のセクションが追記され、
     方向性・変更点・検証証跡・未消化項目が記録されている。
   - README.md に UI の説明があれば整合させる(無ければ変更しない)。

3. REQUIRED SKILLS
   なし。

4. REQUIRED TOOLS
   Read, Edit, Bash(git status / git log のみ)

5. MUST DO
   - 実装後のコード(Sources/CasRec/UI/ と Library/LibraryView.swift)を読み、
     文書が実装と一致していることを1項目ずつ確認してから書く。
   - DESIGN.md §7 の ASCII ワイヤフレームを新構成に描き直す。
   - tasks/todo.md には、既存セクションの書式(見出し + チェックボックス + 証跡)に揃えて追記する。
   - tasks/ui-redesign-spec.md と tasks/ui-redesign-tasks.md へのリンクを DESIGN.md §7 から張る。

6. MUST NOT DO
   - 他のエージェントを起動しない。
   - Sources/ 配下を変更しない。
   - tasks/todo.md の既存記述を書き換えない(追記のみ)。
   - tasks/todo.md の本文に "UNVERIFIED" という文字列を書かない
     (Stop フックが台帳未決着と誤検知する。説明文では「未検証」と書く)。
   - git commit / push をしない。

7. CONTEXT
   - DESIGN.md §7 が現行のUI設計。ワイヤフレームは行録画画面の構成を示している。
   - tasks/todo.md は Phase 1 の実装計画で、以降 PR ごとのレビュー記録が Notes に追記されている。
   - 設計からの逸脱は Notes に記録し、設計書も更新するのがこのリポジトリの規約。
```

**レビューチェック(T7)**
- [ ] DESIGN.md §7 のワイヤフレームが実装と一致
- [ ] failed バナーの記述が新構成に合わせて更新されている
- [ ] todo.md に "UNVERIFIED" の文字列が入っていない
- [ ] `Sources/` の差分がゼロ

---

## 全体の完了条件

- [ ] T1〜T7 すべてレビュー通過
- [ ] `swift build` exit 0 / 警告0
- [ ] `make test` の件数がリデザイン前から減っていない
- [ ] `make bundle` 成功、`open CasRec.app` で起動
- [ ] 実機確認: ライト/ダーク両外観、ウィンドウ幅 780 と 1600、
      idle / 録画中 / 失敗 / 予約済み / 権限拒否 の各表示
- [ ] キーボードだけで 対象選択 → 設定変更 → 録画開始 → 停止 まで到達できる
- [ ] CI 緑
