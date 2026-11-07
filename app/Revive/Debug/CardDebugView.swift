#if DEBUG
import CardLink
import CardProtocol
import SwiftUI

/// Debug entry for real-card verification (#38). Replaced by the real screens in #41.
struct CardDebugView: View {
    @Bindable var model: CardDebugModel

    var body: some View {
        NavigationStack {
            List {
                Section("蓝牙：\(String(describing: model.state))") {
                    HStack {
                        Button("扫描") { model.startScan() }
                        Spacer()
                        Button("停止") { model.stopScan() }
                        Spacer()
                        Button("等待重连") { model.connectWhenSeen() }
                        Spacer()
                        Button("断开") { model.disconnect() }
                    }
                    ForEach(model.cards, id: \.id) { card in
                        Button("\(card.name ?? "?")  fw \(card.advertisement.firmware)  电量 \(card.advertisement.battery)%  RSSI \(card.rssi)") {
                            model.stopScan()
                            model.connect(card.id)
                        }
                    }
                    if let id = model.lastPeripheral {
                        Button("连接上次的卡") { model.connect(id) }
                        Button("杀进程（状态恢复测试）", role: .destructive) { model.killForRestoration() }
                    }
                }
                Section("设备") {
                    HStack {
                        Button("信息") { model.info() }
                        Spacer()
                        Button("开关") { model.switches() }
                        Spacer()
                        Button("录音状态") { model.recordingStatus() }
                        Spacer()
                        Button("校时") { model.syncTime() }
                    }
                    HStack {
                        Button("配对") { model.pair() }
                        Spacer()
                        Button("解绑", role: .destructive) { model.unpair() }
                    }
                    HStack {
                        Button("开始") { model.startRecording() }
                        Spacer()
                        Button("暂停") { model.pause() }
                        Spacer()
                        Button("继续") { model.resume() }
                        Spacer()
                        Button("停止") { model.stopRecording() }
                    }
                    if model.busy { ProgressView(value: model.progress) }
                }
                Section("文件（点按下载校验，长按更多）") {
                    Button("列表") { model.listFiles() }
                    ForEach(model.files, id: \.name) { file in
                        Text("\(file.name)  \(file.size) B" + (model.storedLocally.contains(file) ? "  ✓ 已存手机" : ""))
                            .onTapGesture { model.download(file) }
                            .contextMenu {
                                Button("续传测试") { model.resumeTest(file) }
                                Button("删除卡上文件", role: .destructive) { model.delete(file) }
                                    .disabled(!model.storedLocally.contains(file))
                            }
                    }
                }
                Section("日志") {
                    HStack {
                        ShareLink(item: DebugLog.fileURL) { Text("导出 card-debug.log") }
                        Spacer()
                        Button("清空", role: .destructive) { model.log.clear() }
                    }
                    ForEach(Array(model.log.lines.suffix(120).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                    }
                }
            }
            .buttonStyle(.borderless)
            .navigationTitle("Card Debug")
            .alert("此卡已被其他设备绑定", isPresented: $model.rebindPending) {
                Button("重新绑定", role: .destructive) { model.answerRebind(true) }
                Button("取消", role: .cancel) { model.answerRebind(false) }
            } message: {
                Text("重新绑定后原设备将无法管理此卡。卡上的录音不受影响。")
            }
        }
    }
}
#endif
