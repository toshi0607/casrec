import SwiftUI

struct UsageNoticeSheet: View {
    let acknowledge: () -> Void
    let exit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ご利用上の注意")
                .font(.title2)
                .fontWeight(.semibold)

            Text("""
            CasRecは汎用の画面収録ツールです。

            自分が権利を有するコンテンツ、または録画について必要な許可を得ているコンテンツにのみ使用してください。

            録画する際は、著作権、プライバシー、秘密保持義務、利用するサービスの規約、および配信者やイベント主催者が定める条件を確認してください。

            必要な許可がない録画物を、再配布、アップロードまたは第三者へ共有しないでください。また、DRMその他の技術的保護手段の解除・回避に使用しないでください。

            会議、通話、マイク音声など他の人が関係する内容を録画する場合は、必要に応じて事前に通知し、同意を得てください。

            CasRecは、個々の録画が適法かどうかを判定または保証するものではありません。

            「理解して続ける」は、この案内を確認したことを記録するための操作であり、契約への同意を求めるものではありません。
            """)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("終了", action: exit)
                Spacer()
                Button("理解して続ける", action: acknowledge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
