import AVFoundation
import SwiftUI

@main
struct DNoteProbeApp: App {
    @StateObject private var probe = Probe()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(probe)
                .task { await probe.autoRunIfRequested() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var probe: Probe
    @ObservedObject var log = ProbeLog.shared
    @State private var player: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            List {
                Section("蓝牙 \(probe.state)") {
                    Toggle("只扫 FE98（后台可用）", isOn: $probe.scanFE98Only)
                    HStack {
                        Button("扫描") { probe.startScan() }
                        Spacer()
                        Button("停止") { probe.stopScan() }
                        Spacer()
                        Button("等待重连") { probe.connectWhenSeen() }
                    }.buttonStyle(.borderless)
                    ForEach(probe.cards) { card in
                        Button {
                            probe.run("connect") {
                                try await probe.connect(card.peripheral)
                                try await probe.deviceInfo()
                            }
                        } label: {
                            Text("\(card.peripheral.name ?? "?") fw \(card.adv.firmware) 电量 \(card.adv.battery)% RSSI \(card.rssi)")
                        }
                    }
                }
                if probe.connected != nil {
                    Section("会话") {
                        HStack {
                            Button("状态") { probe.run("status") { try await probe.status() } }
                            Spacer()
                            Button("停录") { probe.run("stop") { try await probe.stopRecording() } }
                            Spacer()
                            Button("配对") { probe.run("pair") { try await probe.pair() } }
                            Spacer()
                            Button("解绑") { probe.run("unpair") { try await probe.unpair() } }
                            Spacer()
                            Button("列表") { probe.run("list") { try await probe.listFiles() } }
                            Spacer()
                            Button("断开") { probe.disconnect() }
                        }.buttonStyle(.borderless)
                        Button("热点测试（FastUpload）") { probe.run("hotspot") { try await probe.hotspotProbe() } }
                        Button("自动跑 14 轮（#21 A/B 分布）") { probe.run("hotspot-batch") { try await probe.hotspotRuns() } }
                        Button("快传协议探测（#6）") { probe.run("ft-probe") { try await probe.fastTransferProbe() } }
                        Button("热点测试（固定密码，保存网络）") { probe.run("hotspot") { try await probe.hotspotProbe(fixedPsk: true, joinOnce: false) } }
                        HStack {
                            Button("开热点（保持）") { try? probe.hotspotHold(true) }
                            Spacer()
                            Button("关热点") { try? probe.hotspotHold(false) }
                        }.buttonStyle(.borderless)
                        Text("手动热点：FastUpload / 密码 dnote1234").font(.footnote)
                        if probe.busy { ProgressView(value: probe.progress) }
                    }
                    Section("文件（点按下载并播放）") {
                        ForEach(probe.files) { f in
                            Button("\(f.name)  \(f.size) B") {
                                probe.run("download") {
                                    let url = try await probe.download(f)
                                    try AVAudioSession.sharedInstance().setCategory(.playback)
                                    player = try AVAudioPlayer(contentsOf: url)
                                    let ok = player?.play() ?? false
                                    probe.log.add("play: \(url.lastPathComponent) duration=\(player?.duration ?? 0)s started=\(ok)")
                                }
                            }
                        }
                    }
                }
                Section("日志") {
                    ShareLink(item: ProbeLog.fileURL) { Text("导出 probe.log") }
                    ForEach(Array(log.lines.suffix(80).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                    }
                }
            }
            .navigationTitle("D·NOTE Probe")
        }
    }
}
