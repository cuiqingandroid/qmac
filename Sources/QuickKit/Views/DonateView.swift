import AppKit
import SwiftUI

/// 捐赠页：微信 / 支付宝收款码
struct DonateView: View {
    private let codes: [(name: String, file: String, tint: Color)] = [
        ("微信支付", "donate-wechat", Color(red: 0.09, green: 0.72, blue: 0.35)),
        ("支付宝", "donate-alipay", Color(red: 0.09, green: 0.45, blue: 0.95))
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text("请作者喝杯咖啡 ☕️")
                    .font(.system(size: 17, weight: .semibold))
                Text("QuickKit 是免费开源的小工具，觉得顺手的话可以随意打赏，完全自愿。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 18) {
                ForEach(codes, id: \.file) { code in
                    VStack(spacing: 8) {
                        // 收款码是竖版海报（约 3:4），按比例给足高度，别把二维码压小
                        qrImage(code.file)
                            .frame(width: 192, height: 262)
                        Text(code.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(code.tint)
                    }
                }
            }

            Link("项目主页 · GitHub", destination: URL(string: "https://github.com/cuiqingandroid/QuickKit")!)
                .font(.system(size: 12))
        }
        .padding(24)
        .frame(width: 456)
    }

    @ViewBuilder
    private func qrImage(_ file: String) -> some View {
        if let url = Bundle.main.url(forResource: file, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(.tertiary)
                .overlay(
                    Text("收款码未打包\n(assets/\(file).png)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                )
        }
    }
}
