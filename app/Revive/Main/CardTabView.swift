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
                ContentUnavailableView("还没有录音卡", systemImage: "rectangle.portrait")
                    .paperPage()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("切换") { showsSwitcher = true }
                    .accessibilityLabel("切换或添加录音卡")
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
