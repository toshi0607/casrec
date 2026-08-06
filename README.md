# CasRec

CasRec is a personal, general-purpose screen recorder for macOS built with
SwiftUI, ScreenCaptureKit, and AVFoundation. It records a display, an
individual window, or a selected region with application audio and, optionally,
microphone audio. Recordings are stored locally on the user's Mac.

## Features

- Record a display, an individual window, or a selected region in a window
- Capture application audio and optionally microphone audio
- HEVC and H.264 output with fragmented QuickTime recording for improved crash recovery
- Recording scheduling and duration limits
- Local library, compression, GIF conversion, and remux recovery
- No cloud upload or built-in sharing

## Requirements

- macOS 15 or later
- A Swift 6-compatible toolchain
- Screen Recording permission
- Microphone permission when microphone capture is enabled
- `ffmpeg` is optional and used only for GIF conversion and remux recovery

## Install

Download `CasRec-<version>.zip` and `checksums.txt` from
[Releases](../../releases). Replace `<version>` with the version shown on the
release, then extract the ZIP archive and move `CasRec.app` to `/Applications`.

Before installing, verify the downloaded archive against `checksums.txt`:

```sh
shasum -a 256 CasRec-<version>.zip
shasum -a 256 -c checksums.txt
```

Compare the first command's output with the line for `CasRec-<version>.zip` in
the downloaded `checksums.txt` file. The second command should report
`CasRec-<version>.zip: OK`.

The first launch is expected to be blocked by Gatekeeper. CasRec is signed with
a developer's self-signed certificate; it is not signed with an Apple Developer
ID certificate and has not received Apple notarization. On macOS 15 or later,
first attempt to open the app, then go to System Settings > Privacy & Security
and select **Open Anyway**. The right-click > Open flow is not available on
macOS 15 or later. As an alternative, run the following command in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/CasRec.app
```

## Build and run

The repository is a Swift Package with a Makefile. Run these commands from the
repository root:

```sh
make build
make test
make bundle
make run
```

`make bundle` creates and signs `CasRec.app`. `make run` first runs that bundle
step and then opens the app. The default signing identity, `CasRec Release`, is
the maintainer's local self-signed certificate and will not exist on another
Mac. Without a certificate, use ad-hoc signing:

```sh
make bundle CODESIGN_IDENTITY=-
make run CODESIGN_IDENTITY=-
```

You can set `CODESIGN_IDENTITY` to your own signing identity for repeated local
development. Ad-hoc signatures change when the app is rebuilt, so macOS may ask
for Screen Recording permission again after a rebuild.

## Privacy

CasRec processes recordings locally and has no feature for uploading recordings
to an external service. It may write recording diagnostics to macOS Unified
Logging, including recording file names (which can contain an application name)
and error information. Their retention is managed by macOS.

## Legal notice

CasRec is a general-purpose screen recording tool. Only record content that you
own or that you are legally authorized to record. You are responsible for
complying with applicable copyright law, privacy and publicity rights,
confidentiality obligations, service terms, and restrictions specified by
content owners, streamers, event organizers, employers, or other relevant
parties.

Do not redistribute, upload, publicly transmit, sell, or otherwise share a
recording unless you have the necessary permission or another valid legal basis.

Do not use CasRec to circumvent DRM, access controls, copy-protection mechanisms,
or other technical protection measures. CasRec does not implement DRM
circumvention or direct stream downloading. DRM-protected content may not be
recordable.

When recording microphone audio, meetings, calls, or content involving other
people, notify participants and obtain consent when required.

The availability of content for viewing does not necessarily mean that the
content may be recorded or redistributed. CasRec does not determine whether a
particular recording is lawful.

CasRec is provided under the [MIT License](LICENSE), including its disclaimer
of warranties and limitation of liability.

CasRec is not affiliated with, endorsed by, or sponsored by any streaming
service.

## ffmpeg

CasRec does not bundle or redistribute ffmpeg. If it is installed separately on
your Mac, CasRec may invoke it for optional GIF conversion and remux recovery.
ffmpeg is distributed under its own license.

## License

CasRec is available under the [MIT License](LICENSE).

## 日本語

CasRecは、SwiftUI、ScreenCaptureKit、AVFoundationで作られたmacOS向けの汎用的な画面収録アプリです。ディスプレイ、個別のウィンドウ、またはウィンドウ内で選択した範囲を、アプリ音声と必要に応じてマイク音声とともに録画し、録画データはMac内に保存します。

### 主な機能

- ディスプレイ、ウィンドウ、ウィンドウ内の選択範囲の録画
- アプリ音声と任意のマイク音声の録音
- HEVC / H.264出力と、クラッシュ時の復旧性を高めるfragmented QuickTime録画
- 録画予約と録画時間の上限
- ローカルライブラリ、圧縮、GIF変換、remuxによる復旧
- クラウドへのアップロードやアプリ内共有機能はなし

### 動作環境

- macOS 15以降
- Swift 6対応のツールチェーン
- 画面収録の許可
- マイク録音を有効にする場合はマイクの許可
- `ffmpeg` は任意で、GIF変換とremuxによる復旧にのみ使用

### インストール

[Releases](../../releases) から `CasRec-<version>.zip` と `checksums.txt` をダウンロードします。`<version>` はリリースに表示されているバージョンへ置き換えてください。ZIPアーカイブを展開し、`CasRec.app` を `/Applications` へ移動します。

インストール前に、ダウンロードしたアーカイブを `checksums.txt` と照合します。

```sh
shasum -a 256 CasRec-<version>.zip
shasum -a 256 -c checksums.txt
```

1つ目のコマンドの出力を、ダウンロードした `checksums.txt` にある `CasRec-<version>.zip` の行と比較してください。2つ目のコマンドでは `CasRec-<version>.zip: OK` と表示されることを確認します。

初回起動時はGatekeeperによってブロックされることが想定されます。CasRecは開発者の自己署名証明書で署名されており、Apple Developer IDによる署名およびAppleの公証（notarization）を受けていません。macOS 15以降では、まずアプリの起動を試し、その後にシステム設定 → プライバシーとセキュリティ → 「このまま開く」を選択してください。macOS 15以降では「右クリック → 開く」は使えません。代替として、ターミナルで次を実行できます。

```sh
xattr -dr com.apple.quarantine /Applications/CasRec.app
```

### ビルドと起動

リポジトリのルートで以下を実行します。

```sh
make build
make test
make bundle
make run
```

`make bundle` は `CasRec.app` を作成して署名します。`make run` はバンドル作成後にアプリを開きます。既定の署名IDである `CasRec Release` はメンテナのローカル自己署名証明書であり、他のMacには存在しません。証明書がない場合は、ad-hoc署名で実行できます。

```sh
make bundle CODESIGN_IDENTITY=-
make run CODESIGN_IDENTITY=-
```

繰り返しローカル開発する場合は、`CODESIGN_IDENTITY` に自身の署名IDを指定できます。ad-hoc署名では再ビルドのたびに署名が変わるため、macOSが画面収録の許可を再度求めることがあります。

### プライバシー

録画データはローカルで処理され、外部サービスへアップロードする機能はありません。録画に関する診断情報はmacOSのUnified Loggingへ記録されることがあり、録画ファイル名（対象アプリ名を含む場合があります）やエラー情報を含む場合があります。保持期間はmacOSの管理に従います。

### 利用上の注意

CasRecは汎用の画面収録ツールです。

自分が権利を有するコンテンツ、または録画について必要な許可を得ているコンテンツにのみ使用してください。利用者は、著作権法、プライバシー権・肖像権、秘密保持義務、各サービスの利用規約、ならびに配信者、イベント主催者、雇用主その他の関係者が定める制限を確認し、遵守する責任を負います。

必要な許可または法的根拠がない限り、録画物を再配布、アップロード、公衆送信、販売または第三者へ共有しないでください。

DRM、アクセス制御、コピー防止その他の技術的保護手段の解除・回避にCasRecを使用しないでください。CasRecには、DRMを回避する機能やストリームを直接ダウンロードする機能はありません。DRMで保護されたコンテンツは録画できない場合があります。

マイク音声、会議、通話または他の人が関係する内容を録画する場合は、必要に応じて事前に参加者へ通知し、同意を得てください。

コンテンツを視聴できることは、そのコンテンツの録画や再配布が許可されていることを意味するとは限りません。CasRecは、個々の録画が適法かどうかを判定しません。

CasRecは、無保証および責任制限を含む[MIT License](LICENSE)に基づいて提供されます。

CasRecは、いかなる配信サービスとも提携、公認または後援関係にありません。

### ffmpegについて

CasRecはffmpegを同梱・再配布しません。Macに別途インストールされている場合のみ、GIF変換とremuxによる復旧に利用します。ffmpegにはCasRecとは別のライセンスが適用されます。

### ライセンス

CasRecは[MIT License](LICENSE)で公開しています。
