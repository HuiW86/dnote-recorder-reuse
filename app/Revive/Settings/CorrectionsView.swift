import AppModel
import Library
import SwiftUI

/// 纠错词库 (#75): words corrected in transcripts, replaced in later ones. Swipe to delete.
struct CorrectionsView: View {
    let env: AppEnvironment
    @State private var model: CorrectionsModel?

    var body: some View {
        Group {
            if let model {
                CorrectionsList(model: model)
            } else {
                ProgressView().paperPage()
            }
        }
        .navigationTitle("纠错词库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil, let library = env.library { model = CorrectionsModel(library: library) }
            model?.reload()
        }
    }
}

private struct CorrectionsList: View {
    @Bindable var model: CorrectionsModel

    var body: some View {
        List {
            if model.corrections.isEmpty {
                ContentUnavailableView("还没有纠错的词", systemImage: "character.cursor.ibeam",
                                       description: Text("在录音详情的文字稿里长按一句，选「修改这一句」，改正听错的词。"))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.corrections) { correction in
                        HStack(spacing: 8) {
                            Text(correction.wrong).foregroundStyle(Theme.inkMuted).strikethrough()
                            Image(systemName: "arrow.right").foregroundStyle(Theme.inkMuted).accessibilityHidden(true)
                            Text(correction.right).foregroundStyle(Theme.ink)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(correction.wrong) 改成 \(correction.right)")
                        .swipeActions {
                            Button("删除") { model.delete(correction) }.tint(.red)
                        }
                    }
                } footer: {
                    Text("只影响以后的转写；已经有的文字稿不变。")
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .toast($model.toast)
    }
}
