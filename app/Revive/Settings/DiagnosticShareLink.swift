import AppModel
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "导出诊断信息" (product-spec.md P09, §7.1): the system share sheet with the redacted log
/// plus the app and system versions. The file is only written once the user picks a target.
struct DiagnosticShareLink: View {
    let log: DiagnosticLog

    var body: some View {
        ShareLink(item: DiagnosticExport(header: Self.header, contents: { log.contents() }),
                  preview: SharePreview("声笺诊断信息")) {
            Text("导出诊断信息")
        }
    }

    @MainActor private static var header: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?"))"
        let device = UIDevice.current
        return "声笺 \(version), \(device.systemName) \(device.systemVersion), \(device.model)\n"
    }
}

private struct DiagnosticExport: Transferable {
    let header: String
    let contents: @MainActor () -> String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            let body = await export.contents() ?? "（暂无记录）\n"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("revive-diagnostics.txt")
            try Data((export.header + "\n" + body).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
