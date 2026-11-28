import AppModel
import SwiftUI

/// 录音卡 tab (#89): the current card's page (P07), switching cards (P08), and settings (P09)
/// from the top right.
struct CardTabView: View {
    @Bindable var model: HomeModel
    let env: AppEnvironment
    @Binding var showsSwitcher: Bool

    var body: some View {
        Group {
            if let device = model.currentDevice {
                // A new id after switching cards gives the page a fresh model.
                DeviceView(env: env, deviceId: device.id, isTab: true).id(device.id)
            } else {
                // 先不连卡, or the last card was unpaired (product-spec.md P07).
                ContentUnavailableView {
                    Label("还没有录音卡", systemImage: "rectangle.portrait")
                } description: {
                    Text("没有录音卡也能用：点底栏中间的红键用这部手机录，或者在「录音」里导入音频和文字。")
                } actions: {
                    if env.isCardless {
                        Button("添加录音卡") { env.addFirstCard() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        NavigationLink(value: Route.connectGuide) { Text("添加录音卡") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .paperPage()
            }
        }
        .toolbar {
            // With no card the page's own button adds one.
            if model.currentDevice != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("切换") { showsSwitcher = true }
                        .accessibilityLabel("切换或添加录音卡")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
    }
}
