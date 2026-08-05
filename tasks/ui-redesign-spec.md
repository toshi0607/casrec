# CasRec UI リデザイン仕様書 — 方向性「デッキ」

作成: 2026-08-05 / 対象ブランチ: `claude/frontend-modern-design-dfec28`
この文書は実装エージェントへの**単一の真実**である。迷ったらこの文書の数値・文言をそのまま使い、判断が必要になったら実装せずに報告する。

関連: [DESIGN.md](../DESIGN.md) §7(UI設計) / [ui-redesign-tasks.md](ui-redesign-tasks.md)(タスク分割と委譲プロンプト)

---

## 0. これは何を変え、何を変えないか

**変えるもの**: 見た目(配色・タイポグラフィ・余白・角丸・カード構造)、画面の骨格(タブ → サイドバー + 下部固定デッキ)、文言(英日混在 → 日本語で統一)。

**変えないもの**: 情報構成(DESIGN.md §7 の項目は1つも削らない・増やさない)、状態機械、`RecordingControls` / `RecordingSession` / `CaptureService` / `Contracts` の API、既存テスト。**Viewファイル以外を触る変更が必要になったら、実装せず報告する。**

書き込みが許されるのは以下だけ:

```
Sources/CasRec/UI/*.swift
Sources/CasRec/Library/LibraryView.swift
Sources/CasRec/App/MenuBarControls.swift   (T6 のみ、アイコン色の一箇所)
```

---

## 1. デザイン方向性

**「デッキ」** — 録画機の操作卓。

ウィンドウ下部に固定された**トランスポートデッキ**が、録画状態機械(idle / preparing / recording / finishing / failed)の唯一の顔になる。デッキには常に大きな等幅タイムコードが表示され、待機中は淡く沈み、録画中に色を得る。上部に走る2ptのラインが録画時間の上限に対する進捗を示す(テープの残量)。

上半分は設定領域。タブをやめてサイドバー(録画 / ライブラリ)にし、設定はマテリアルのカード群へ整理する。デッキが常時見えるので、ライブラリを見ながらでも開始・停止でき、**録画失敗もどちらの画面でも見える**(DESIGN.md §7 の「ライブラリタブ表示中はバナーが見えない」という既知の弱点が解消される)。

大胆さはデッキ1点に集中させる。カード・ピッカー・リストは徹底して静かに作る。装飾は足さない。

### なぜこの形か

- 録画機の主役は「いま録れているか」と「どれだけ録れたか」の2つ。それを画面の固定位置に置くと、設定をスクロールしても、ライブラリを見ていても、視線を動かさずに確認できる。
- 番号付きマーカー(01/02/03)、グラデーションの見出し、ヒーロー数値カードのような汎用装飾は**使わない**。この画面に順序情報はない。
- 赤は「録画中およびその失敗」だけに使う。警告は琥珀、操作色はティール。色が状態を一意に指す。

---

## 2. デザイントークン

すべて `Sources/CasRec/UI/DesignSystem.swift` に定義し、他のViewはここからのみ色・寸法・書体を取る。View内での `Color.blue` / `Color.red` / `.cornerRadius(8)` の直書きは禁止。

### 2.1 配色

ライト/ダーク両対応。`NSColor(name:dynamicProvider:)` で動的色を作る。**クロージャの外の `NSColor` をキャプチャしない**(Swift 6 の Sendable 制約を踏むため、クロージャ内で数値から生成する):

```swift
private func dynamicColor(
    light: (red: Double, green: Double, blue: Double),
    dark: (red: Double, green: Double, blue: Double)
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    })
}
```

| トークン | ライト | ダーク | 用途 |
|---------|--------|--------|------|
| `Theme.signal` | `#C9251B` (0.788, 0.145, 0.106) | `#FF4B3E` (1.000, 0.294, 0.243) | 録画中の表示、録画ボタン、録画の失敗。**これ以外に使わない** |
| `Theme.accent` | `#0E8E99` (0.055, 0.557, 0.600) | `#3ECBD8` (0.243, 0.796, 0.847) | 選択状態、トグル、ピッカー等すべての操作色 |
| `Theme.caution` | `#A9741A` (0.663, 0.455, 0.102) | `#E0A63C` (0.878, 0.651, 0.235) | 警告(空き容量・フレーム停止・保存先の異常・予約の警告) |
| `Theme.cardFill` | `Color(nsColor: .controlBackgroundColor)` | 同 | カード面 |
| `Theme.hairline` | `Color(nsColor: .separatorColor)` | 同 | カード境界・区切り線 |

- 操作色はルート(`NavigationSplitView` 直下)に `.tint(Theme.accent)` を1回だけ当てて全コントロールへ伝播させる。個別のコントロールに `.tint` を付けない。
- テキスト色は `.primary` / `.secondary` / `.tertiary` を使う。トークン化しない。
- バナー背景は `色.opacity(0.10)`、枠線は `色.opacity(0.28)`。
- 録画中のデッキ背景の色被せは `Theme.signal.opacity(0.07)`、失敗時も同じ値。

### 2.2 タイポグラフィ

**散文は SF Pro(システム既定)、機械が出した値はすべて SF Mono(`design: .monospaced`)**。この分担を例外なく守ることが、この画面の型システムそのもの。日本語ラベルは常に SF Pro。

```swift
extension Font {
    static func machine(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
```

| 役割 | 指定 | 色 |
|------|------|-----|
| タイムコード(デッキの主役) | `.machine(34, weight: .light).monospacedDigit()` | 録画中 `.primary` / preparing・finishing `.secondary` / idle `.tertiary` |
| デッキのサブライン | `.system(size: 11)` | `.secondary`(失敗時のみ `Theme.signal`) |
| 計測値のラベル(サイズ/ドロップ) | `.system(size: 10, weight: .medium)` + `.tracking(0.4)` | `.secondary` |
| 計測値の数値 | `.machine(13, weight: .medium)` | `.primary` |
| カード見出し | `.system(size: 12, weight: .semibold)` + `.tracking(0.5)` | `.secondary` |
| フィールドラベル | `.system(size: 11)` | `.secondary` |
| 本文・コントロール | 既定(指定しない) | 既定 |
| 補足・注記 | `.system(size: 11)` | `.secondary` |
| 機械値のインライン表示(パス・寸法・件数・時刻) | `.machine(11)` | 文脈に従う |

### 2.3 寸法

```swift
enum Theme {
    enum Metric {
        static let cardRadius: CGFloat = 12      // 角丸は .continuous スタイル
        static let cardPadding: CGFloat = 14
        static let cardSpacing: CGFloat = 14     // カード間
        static let gutter: CGFloat = 16          // ペイン内の外周余白
        static let contentMaxWidth: CGFloat = 760
        static let controlRadius: CGFloat = 8    // バナー・サムネイル
        static let chipRadius: CGFloat = 6
    }
}
```

- ウィンドウ最小サイズ: `minWidth: 780, minHeight: 580`
- サイドバー幅: `min: 168, ideal: 176, max: 220`
- デッキ: 横 `20`、縦 `12`、上部プログレストラック高 `2`、録画ボタン直径 `52`
- ソースサムネイル: `132 × 82`、角丸 `8`、選択時はティール2ptのリング + 20%のハロー3pt
- ライブラリのサムネイル: `112 × 63`、角丸 `6`

### 2.4 モーション

- 録画中の赤いランプ: `opacity 1.0 ⇄ 0.5`、`.easeInOut(duration: 1.1).repeatForever(autoreverses: true)`
- 状態遷移: デッキ全体に `.animation(.snappy(duration: 0.25), value: <状態を表す値>)`
- **これ以外のアニメーションは追加しない。**
- `@Environment(\.accessibilityReduceMotion)` が true のときはランプの明滅を止め、静止した不透明度 1.0 にする。

---

## 3. 共通コンポーネント(`DesignSystem.swift`)

以下のシグネチャで実装する。呼び出し側(T2〜T6)はこの通りに使う。

```swift
/// 設定領域のカード。見出し + 右肩の任意アクセサリ + 本体。
struct SectionCard<Accessory: View, Content: View>: View {
    init(_ title: String,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content)
}
extension SectionCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content)
}
```
見た目: `VStack(alignment: .leading, spacing: 12)` の中身を `Theme.Metric.cardPadding` で包み、`Theme.cardFill` を `RoundedRectangle(cornerRadius: 12, style: .continuous)` で敷き、同形の `strokeBorder(Theme.hairline)` を1pt重ねる。見出し行は `HStack { Text(title).cardTitleStyle(); Spacer(); accessory }`。

```swift
/// 状態の通知。アプリ内のバナーはすべてこれ1つに統一する。
struct NoticeBanner<Extra: View>: View {
    enum Severity { case info, caution, critical }
    init(_ severity: Severity,
         title: String? = nil,
         message: String,
         @ViewBuilder extra: () -> Extra)
}
extension NoticeBanner where Extra == EmptyView {
    init(_ severity: Severity, title: String? = nil, message: String)
}
```
見た目: 左に SF Symbol(`info` → `info.circle.fill` / `caution` → `exclamationmark.triangle.fill` / `critical` → `exclamationmark.octagon.fill`)、右に `title`(あれば `.system(size: 12, weight: .semibold)`)と `message`(`.system(size: 11)`, `.secondary`)、その下に `extra`。背景は重大度の色 10%、枠線は 28%、角丸 `controlRadius`。`.frame(maxWidth: .infinity, alignment: .leading)`。

```swift
/// ラベルを上、コントロールを下に置く縦組みのフィールド。
struct FieldRow<Control: View>: View {
    init(_ label: String, @ViewBuilder control: () -> Control)
}
```

```swift
extension View {
    func cardTitleStyle() -> some View   // 12/semibold/tracking 0.5/secondary
    func fieldLabelStyle() -> some View  // 11/secondary
    func metaStyle() -> some View        // 11/secondary
}
```

---

## 4. 画面の骨格

```
┌──────────────┬───────────────────────────────────────────┐
│              │  ← 詳細ペイン (ScrollView, 最大幅760, 中央) │
│  ◉ 録画      │  ╭─ 対象 ──────────[ウィンドウ|画面全体]─╮ │
│  ▤ ライブラリ │  │ ┌────┐┌────┐┌────┐┌────┐          │ │
│              │  │ │thumb││thumb││thumb││thumb│  →      │ │
│              │  │ └────┘└────┘└────┘└────┘          │ │
│              │  │ [領域を選択] 領域 1714×946 [クリア]   │ │
│              │  ╰─────────────────────────────────────╯ │
│              │  ╭─ 音声 ──────────────────────────────╮ │
│              │  │ ( ) アプリの音声   ( ) マイク         │ │
│              │  ╰─────────────────────────────────────╯ │
│              │  ╭─ 画質と上限 ────────────────────────╮ │
│              │  │ コーデック [HEVC ▾]  解像度 [100% ▾] │ │
│              │  │ フレームレート [30 ▾] 上限 [なし ▾]  │ │
│              │  ╰─────────────────────────────────────╯ │
│              │  ╭─ 保存先 ────────────────────────────╮ │
│              │  │ ~/Movies/CasRec            [変更…]  │ │
│              │  ╰─────────────────────────────────────╯ │
│              │  ╭─ 予約 ──────────────────────────────╮ │
│              │  │ [2026/08/05 21:30 ▾]     [予約する] │ │
│              │  ╰─────────────────────────────────────╯ │
├──────────────┴───────────────────────────────────────────┤
│▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ ← 上限への進捗(2pt)  │
│  ⬤    00:42:13                サイズ  ドロップ   ◷ 00:30 │
│  録画  Safari — Release notes  1.2 GB      0             │
└──────────────────────────────────────────────────────────┘
```

- ルートは `NavigationSplitView`。サイドバーは `List(selection:)` に2項目、`.listStyle(.sidebar)`、`.navigationSplitViewColumnWidth(min: 168, ideal: 176, max: 220)`。
- ルートに `.navigationTitle("CasRec")`、各ペインに `.navigationSubtitle("録画")` / `.navigationSubtitle("ライブラリ")`。
- デッキは詳細ペインの `.safeAreaInset(edge: .bottom, spacing: 0)` に置く。**両ペインで見える**こと。
- ライブラリの「更新」ボタンは `.toolbar` へ移し、ペイン内の見出し行は削除する。

---

## 5. トランスポートデッキ(この設計の主役)

`Sources/CasRec/UI/TransportDeck.swift` に新規作成。既存の `StatusView.swift` は役目を引き継いで**削除**する。

```swift
struct TransportDeck: View {
    let state: RecordingState
    let maximumDuration: TimeInterval?
    /// 録画対象の表示名。`source.appName ?? source.title`。
    let sourceTitle: String?
    let canStart: Bool
    let start: () -> Void
    let stop: () -> Void
    let dismissFailure: () -> Void
}
```

構造(上から順に):

1. **プログレストラック**(高さ2pt、幅いっぱい)
   - 録画中かつ `maximumDuration != nil`: 背景 `Theme.hairline`、経過割合ぶんを `Theme.signal` で塗る。割合は `min(1, 経過秒 / maximumDuration)`。
   - それ以外: `Theme.hairline` の1pxライン(実質 `Divider()` 相当)。
2. **警告ストリップ**(録画中に `progress.diskWarning` / `progress.isStalled` が立っているときだけ、それぞれ1行)
   - `NoticeBanner(.caution, title:message:)` を横幅いっぱいで、デッキ内に角丸なしで敷いてもよいし、`gutter` を空けてバナーとして置いてもよい。見た目の一貫性を優先すること。
   - 空き容量: title `空き容量が少なくなっています` / message `保存先の空き容量が5GB未満です。2GB未満になると録画を自動停止します`
   - 停止: title `フレームが届いていません` / message `10秒以上フレームが届いていません。対象ウィンドウが最小化されていないか確認してください`
3. **メイン行** `HStack(alignment: .center, spacing: 16)`
   - **録画ボタン**(直径52)
   - **タイムコード + サブライン** `VStack(alignment: .leading, spacing: 2)`
   - `Spacer(minLength: 12)`
   - **計測値レール**(録画中のみ): サイズ / ドロップ / 音声エラー(`audioAppendFailures > 0` のときだけ)。各項目は `VStack(alignment: .trailing, spacing: 2)` でラベル上・数値下。項目間は高さ22の `Divider()`。
   - **上限バッジ**(`maximumDuration != nil` のとき): 小さなリング(直径18、`Circle().trim`、`Theme.signal`、`.rotationEffect(.degrees(-90))`、`lineWidth: 2`、録画中のみ進捗を描く)+ `.machine(11)` の `00:30` 表記。
   - **失敗時**: 計測値の代わりに `閉じる` ボタン(`.borderless`)を置き、押下で `dismissFailure()`。

背景: `Rectangle().fill(.bar)` の上に、録画中/失敗時のみ `Theme.signal.opacity(0.07)` を重ねる。

### 5.1 状態ごとの表示

| 状態 | タイムコード | サブライン | ボタン |
|------|------------|-----------|--------|
| idle(対象あり) | `00:00:00` `.tertiary` | `Safari — Release notes ・ ⌥⌘R でも開始できます` | 赤い円(有効) |
| idle(対象なし) | `00:00:00` `.tertiary` | `録画対象を選択してください` | 赤い円(無効・30%) |
| preparing | `00:00:00` `.secondary` | `録画を開始しています` | 小さな `ProgressView`(無効) |
| recording | 実時間 `.primary` | 対象名 | 赤い角丸四角(停止・明滅) |
| finishing | 最後の時間 `.secondary` | `ファイルを書き出しています` | 小さな `ProgressView`(無効) |
| failed | `00:00:00` `.tertiary` | `録画に失敗しました: <message>`(`Theme.signal`、`lineLimit(1)` + `.help(message)`) | 赤い円(無効) |

- タイムコードは `TimelineView(.periodic(from: .now, by: 1))` で1秒ごとに更新する(`RecordingProgress` の更新に依存させない。フレーム停止中も時計は進む)。書式は `%02d:%02d:%02d`。
- 録画ボタンには `.help("録画を開始 (⌥⌘R)")` / `.help("録画を停止 (⌥⌘R)")` と `.accessibilityLabel` を付ける。**`.keyboardShortcut` は付けない**(Carbon のグローバルホットキーと二重発火するため)。
- ボタンは `.buttonStyle(.plain)` + `.contentShape(Circle())`。キーボードフォーカスが見えることを確認する。

### 5.2 録画ボタンの造形

```
idle/failed:   ◯ の中に ● (直径20の円、Theme.signal)
recording:     ◯ の中に ■ (18角丸4の四角、Theme.signal)+ 明滅 + shadow(Theme.signal 45%, radius 8)
preparing/finishing: ◯ の中に ProgressView().controlSize(.small)
無効時:        Theme.signal.opacity(0.3)
```
外周は `Circle().fill(Theme.cardFill)` + `Circle().strokeBorder(Theme.hairline, lineWidth: 1)`。

---

## 6. 録画ペインのカード

上から: 通知 → 対象 → 音声 → 画質と上限 → 保存先 → 予約。カード間 `14`、外周 `16`、`frame(maxWidth: 760)` で中央寄せ。

### 6.1 通知(カードの外、最上部)

`controls.quickStartBannerMessage`(caution) と `controls.durationLimitBannerMessage`(info、アイコンは `stop.circle.fill` のままでよい)を `NoticeBanner` で表示。存在するときだけ。

### 6.2 対象

- カード見出しのアクセサリに `Picker` の `.segmented`(`ウィンドウ` / `画面全体`)、`.labelsHidden()`、`.frame(maxWidth: 200)`。
- 本体はソースの横スクロールストリップ(`SourcePickerView`)。
- `sourcesUnavailable` が非nilのときはストリップの代わりに `NoticeBanner(.caution)`:
  - `permissionDenied`: title `画面収録が許可されていません` / message `システム設定の「プライバシーとセキュリティ > 画面収録」で CasRec を許可してください。` / extra に `Button("システム設定を開く")` と 注記 `許可した後は、CasRec を再起動すると録画できるようになります。`(`.metaStyle()`)
  - `failed(message)`: title `録画対象を取得できません` / message はそのまま。
- ソースが0件で理由もないとき: `録画できるウィンドウがありません` を `.metaStyle()` で1行。
- ウィンドウモードのときだけ最下段に領域の行: `Button("領域を選択")`(読み込み中は `領域を準備中…`)、選択済みなら `領域 1714×946`(`.machine(11)`、`Theme.accent.opacity(0.14)` のカプセル)と `Button("クリア")`。

### 6.3 音声

`Toggle("アプリの音声")` と `Toggle("マイク")` を `HStack(spacing: 24)`。`.toggleStyle(.switch)`、`.controlSize(.small)`。

### 6.4 画質と上限

`Grid(horizontalSpacing: 20, verticalSpacing: 12)` の2列2行。各セルは `FieldRow`:

| ラベル | コントロール | 選択肢 |
|--------|------------|--------|
| コーデック | `Picker` `.menu` | `HEVC` / `H.264` |
| 解像度 | `Picker` `.menu` | `100%` / `50%` |
| フレームレート | `Picker` `.menu` | `30` / `60` |
| 録画時間の上限 | `Picker` `.menu` | `RecordingDurationLimit.allCases` の `pickerLabel` |

### 6.5 保存先

1行: パスを `.machine(11)` + `.lineLimit(1)` + `.truncationMode(.middle)`、右端に `Button("変更…")`。`controls.outputDirectoryWarning` があればその下に `NoticeBanner(.caution)`。

### 6.6 予約

- 未予約: `DatePicker`(`.labelsHidden()`)+ `Button("予約する")`。
- 予約済み: `TimelineView(.periodic(from: .now, by: 60))` の中で `予約済み 21:30 開始`(時刻は `.machine(11)`)+ `あと12分` + 右端 `Button("キャンセル")`。背景に `Theme.accent.opacity(0.10)` のカプセル行にしてよい。
- `controls.scheduleBannerMessage` があれば `NoticeBanner(.caution)`。
- 末尾に注記 `予約はアプリ起動中のみ有効です。アプリを終了すると消えます。`(`.metaStyle()`)。

---

## 7. ライブラリペイン

- ペイン内の見出し行(`Text("ライブラリ").font(.title2)` + 更新ボタン)を削除し、更新は `.toolbar` の `Button` + `.help("一覧を更新")` へ。
- ffmpeg 不在の案内は `NoticeBanner(.info, message: "GIF変換・修復には ffmpeg が必要です。`brew install ffmpeg` でインストールできます。")` にして一覧の上に置く。
- 行:
  - サムネイル `112 × 63`、角丸 `6`、背景 `Theme.hairline.opacity(0.5)`。画像は `.aspectRatio(contentMode: .fill)` の後に固定フレーム → `.clipShape` の順で切る。
  - ファイル名: 既定サイズ `.medium` ウェイト、`.lineLimit(1)`、`.truncationMode(.middle)`。
  - 未finalize バッジ: `Theme.caution.opacity(0.16)` のカプセル、文言は `未finalize` のまま。
  - メタ行: `日時 ・ 時間 ・ サイズ` のうち**時間とサイズは `.machine(11)`**、区切りは `・`。
  - 右端のメニューは `ellipsis.circle`、`.menuStyle(.borderlessButton)` のまま。
- `List` は `.listStyle(.inset)` のまま。行の縦余白は `6`。
- 空状態の `ContentUnavailableView` はそのまま(文言も変えない)。

---

## 8. 文言(英日混在の解消)

インターフェイスの言語は日本語に統一する。同じ動作は最初から最後まで同じ名前で呼ぶ(「録画を開始」で始めたものは「録画中」と表示し、「録画を停止」で終わる)。

| 変更前 | 変更後 |
|--------|--------|
| `Mode` | (ラベル削除。セグメントのみ。`.accessibilityLabel("対象の種類")`) |
| `Window` / `Full Screen` | `ウィンドウ` / `画面全体` |
| `Sources` | (カード見出し「対象」に統合し削除) |
| `Audio` | `音声` |
| `App Audio` / `Microphone` | `アプリの音声` / `マイク` |
| `Settings` | `画質と上限` |
| `Codec` / `Resolution` / `FPS` | `コーデック` / `解像度` / `フレームレート` |
| `Save to` | `保存先` |
| `Start Recording` / `Stop Recording` | `録画を開始` / `録画を停止`(ボタンの `.help` と読み上げラベル) |
| `Starting...` / `Stopping...` | `録画を開始しています` / `ファイルを書き出しています` |
| `Recording Failed` | `録画に失敗しました` |
| `Dismiss` | `閉じる` |
| `Screen Recording Not Allowed` | `画面収録が許可されていません` |
| `Sources Unavailable` | `録画対象を取得できません` |
| `Open System Settings` | `システム設定を開く` |
| `Elapsed` | (タイムコードそのものが主役。ラベル削除) |
| `Size` / `Drops` / `Audio Failures` | `サイズ` / `ドロップ` / `音声エラー` |
| `Low Disk Space` | `空き容量が少なくなっています` |
| `Stalled` | `フレームが届いていません` |
| `領域: 1714×946` | `領域 1714×946` |

そのまま残すもの: `HEVC` / `H.264` / `100%` / `50%` / `30` / `60` / `GB` / `MB` / `Quick Look`(macOS の機能名) / `未finalize`(DESIGN.md の用語) / `ffmpeg` / `brew install ffmpeg` / 既存の日本語文言すべて。

---

## 9. 品質の下限(全タスク共通)

- **キーボード**: すべての操作可能要素にフォーカスが当たり、フォーカスリングが見えること。`.buttonStyle(.plain)` にした録画ボタンで特に確認。
- **読み上げ**: アイコンだけのボタン(更新、行メニュー、録画ボタン)に `.accessibilityLabel` を付ける。
- **モーション**: `accessibilityReduceMotion` で明滅を止める。
- **ダークモード**: 両外観で確認する。ハードコードした白・黒を残さない(`CropPreviewCanvas` の `Color.black` は写真の下敷きなので例外)。
- **可変幅**: ウィンドウ幅 780(最小)〜1600 で崩れないこと。カードは最大幅760で中央寄せ。計測値レールは狭いときに折り返さず、`Spacer(minLength:)` で吸収する。
- **警告ゼロ**: `swift build` が警告0で通ること(このプロジェクトの既定)。

---

## 10. 壊してはならない挙動(変更影響の確認リスト)

見た目を作り替える過程で消えやすい。**各タスクの完了報告で、担当範囲に該当する項目を1つずつ「維持した」と根拠付きで述べること。**

| # | 挙動 | 現在の実装 |
|---|------|-----------|
| 1 | 録画中・終了処理中はソース列挙のポーリングを止める(R5) | `MainView.isPollingSources` + `.task(id:)` |
| 2 | 表示中のモードに属するソースだけを候補にする | `visibleSources` |
| 3 | 選択が候補から外れたら先頭に寄せ直す(モード切替・ウィンドウが閉じたとき) | `syncSelection()` — 列挙更新時とモード変更時の両方で呼ぶ |
| 4 | 選択が変わったら領域指定を解除し、`controls.selectSource` に伝える | `onChange(of: selectedSourceId)` |
| 5 | 領域シートは開いた時点のソースと現在の選択が一致するときだけ初期値と確定値を反映する | `cropPreviewSourceID == selectedSourceId` の2箇所 |
| 6 | 録画が recording → idle に落ちたらライブラリを再読み込みする | `updateRecordingCompletion` + `libraryRefreshToken` |
| 7 | 保存先変更が成功したらライブラリを再読み込みする | `chooseOutputDirectory` |
| 8 | 無効化条件: 領域選択(対象なし/録画中/遷移中/読み込み中)、変更…(録画中/遷移中)、予約する(対象なし)、停止(遷移中)、開始(対象なし) | 各 `.disabled(...)` |
| 9 | ライブラリの削除は録画中・遷移中は不可 | `allowsDeletion: !isRecording && !isTransitioning` |
| 10 | failed は `session.acknowledgeFailure()` を呼ばないと idle に戻らない | 「閉じる」の押下でこれを呼ぶ |
| 11 | 録画中の上限表示は `controls.activeRecordingMaximumDuration` を使う | デッキの上限バッジ |
| 12 | 領域選択の失敗はアラートで知らせる | `showingCropError` / `cropErrorMessage` |
| 13 | 開始は `controls.startManually(source:)`、停止は `session.stop()` を通す | デッキのコールバック |

---

## 11. 検証手順(全タスク共通)

```bash
swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"; grep -c warning: /tmp/build.log
```
```bash
make test 2>&1 | tail -5
```
```bash
make bundle && open CasRec.app
```

- `swift build` は exit 0 かつ警告0。
- `make test` は現行の件数から**減らない**こと(件数を報告に書く)。テストの変更・削除は禁止。
- `swift build` は親ディレクトリを遡って `Package.swift` を拾う。ビルドログに `Sources/CasRec/...` のファイル名が出ていることを確認して、隣のチェックアウトをビルドした偽陽性でないことを示す。
- ビジュアルの確認(ライト/ダーク、幅780と1600、各状態)はレビュー担当が行う。実装エージェントはビルドとテストまでを証跡として出す。
