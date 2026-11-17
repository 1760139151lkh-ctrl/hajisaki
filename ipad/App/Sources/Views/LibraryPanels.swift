import SwiftUI

struct TheaterPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        NavigationStack {
            content().foregroundStyle(palette.text).background(palette.background)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(palette.background, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ConnectionPanel: View {
    @ObservedObject var model: TheaterModel
    @Environment(\.theaterPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    var body: some View {
        TheaterPanel(title: "连接琴房") {
            Form {
                Section {
                    LabeledContent("电脑地址") {
                        TextField("https://", text: $model.hostAddress).multilineTextAlignment(.trailing)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("设备标识") {
                        TextField("配对信息中的设备标识", text: $model.deviceID).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("配对口令") {
                        SecureField("输入新的配对口令", text: $token).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }.listRowBackground(palette.raised)
                Section {
                    Button {
                        Task {
                            await model.connect(token: token)
                            if model.isConnected { token = ""; dismiss() }
                        }
                    } label: {
                        HStack { Text("连接电脑"); Spacer(); if model.connection == .connecting { ProgressView() } }
                    }.disabled(model.connection == .connecting || token.isEmpty || model.deviceID.isEmpty)
                    Button("使用已保存的配对") {
                        Task { await model.reconnect(); if model.isConnected { dismiss() } }
                    }.disabled(model.connection == .connecting)
                    if model.isConnected { Button("断开连接") { model.disconnect() } }
                }.listRowBackground(palette.raised)
                if let notice = model.notice {
                    Section { Text(notice).foregroundStyle(palette.warning).font(.system(size: 14)) }.listRowBackground(palette.raised)
                }
            }.scrollContentBackground(.hidden)
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: TheaterModel
    let onConnect: () -> Void
    @Environment(\.theaterPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var edited: TheaterSettings?
    @State private var exportURL: URL?
    @State private var exporting = false
    @ObservedObject private var audio = TheaterAudio.shared
    @AppStorage("hajisaki.ambience") private var ambienceEnabled = false

    var body: some View {
        TheaterPanel(title: "琴房设置") {
            Form {
                Section("光线") {
                    choiceRow("昼夜", values: [("随系统", "auto"), ("初春琴房", "day"), ("月下剧场", "night")], selection: value(\.theme))
                    choiceRow("透视度", values: [("伴侣纯净", "companion"), ("智能平衡", "balanced"), ("完整记录", "studio")], selection: value(\.transparency))
                }.listRowBackground(palette.raised)
                Section("三轴调音台") {
                    personalitySlider("端庄严谨", lower: "温柔", upper: "严谨", keyPath: \.formality)
                    personalitySlider("讲述分寸", lower: "留白", upper: "细致", keyPath: \.detail)
                    personalitySlider("轻嗔浓度", lower: "克制", upper: "俏皮", keyPath: \.teasing)
                }.listRowBackground(palette.raised)
                Section("声音") {
                    Toggle("琴键音效", isOn: Binding(get: { (edited ?? model.settings).sound }, set: { enabled in
                        var updated = edited ?? model.settings; updated.sound = enabled; edited = updated
                        var saved = model.settings; saved.sound = enabled
                        Task { await model.saveSettings(saved) }
                    }))
                    Toggle("窗边雨声", isOn: $ambienceEnabled)
                    if audio.isSpeaking { Button("停止朗读") { audio.stopSpeech() } }
                    if let notice = audio.notice { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning) }
                }.listRowBackground(palette.raised)
                Section {
                    Button("保存设置") {
                        model.notice = nil
                        Task { await model.saveSettings(edited ?? model.settings); if model.notice == nil { dismiss() } }
                    }
                }.listRowBackground(palette.raised)
                Section("我的琴房") {
                    Button("电脑连接", action: onConnect)
                    Button {
                        exporting = true
                        Task { exportURL = await model.exportLibrary(); exporting = false }
                    } label: {
                        HStack { Text("导出全部记忆与原件"); Spacer(); if exporting { ProgressView() } }
                    }.disabled(exporting || !model.isConnected)
                    if let exportURL { ShareLink(item: exportURL) { Text("保存导出的档案") } }
                }.listRowBackground(palette.raised)
                if let notice = model.notice {
                    Section { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning) }.listRowBackground(palette.raised)
                }
            }.scrollContentBackground(.hidden).onAppear { edited = model.settings }
        }
    }
    private func value(_ keyPath: WritableKeyPath<TheaterSettings, String>) -> Binding<String> {
        Binding(get: { (edited ?? model.settings)[keyPath: keyPath] }, set: { newValue in
            var updated = edited ?? model.settings; updated[keyPath: keyPath] = newValue; edited = updated
        })
    }
    private func choiceRow(_ title: String, values: [(String, String)], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 14))
            HStack(spacing: 6) {
                ForEach(values, id: \.1) { item in
                    Button { selection.wrappedValue = item.1 } label: {
                        Text(item.0).font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 40)
                            .background(selection.wrappedValue == item.1 ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).foregroundStyle(selection.wrappedValue == item.1 ? palette.blue : palette.secondary)
                        .accessibilityLabel(title + "，" + item.0)
                        .accessibilityValue(selection.wrappedValue == item.1 ? "已选中" : "")
                }
            }
        }.padding(.vertical, 5)
    }
    private func personalitySlider(_ title: String, lower: String, upper: String, keyPath: WritableKeyPath<Personality, Int>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15))
                Spacer()
                Text("\((edited ?? model.settings).personality[keyPath: keyPath])%").font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.secondary)
            }
            Slider(value: Binding(get: { Double((edited ?? model.settings).personality[keyPath: keyPath]) }, set: { newValue in
                var updated = edited ?? model.settings; updated.personality[keyPath: keyPath] = Int(newValue); edited = updated
            }), in: 0...100, step: 1).accessibilityLabel(title)
            HStack { Text(lower); Spacer(); Text(upper) }.font(.system(size: 11)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 10)
    }
}

struct MemoryPanel: View {
    @ObservedObject var model: TheaterModel
    @Environment(\.theaterPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var content = ""
    @State private var editingID: String?
    @State private var editorShown = false
    @State private var saving = false
    private var filtered: [MemoryEntry] {
        model.memories.filter { query.isEmpty || $0.content.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        TheaterPanel(title: "记忆星空") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("寻找一段记忆", text: $query).font(.system(size: 15)).padding(12)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                    GlyphButton(label: "记下一件事", glyph: .plus) { content = ""; editingID = nil; editorShown = true }
                }.padding(20)
                if editorShown {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(editingID == nil ? "记下一件事" : "修改这段记忆").font(.system(size: 15, weight: .medium))
                        TextEditor(text: $content).font(.system(size: 16)).frame(minHeight: 100, maxHeight: 180)
                            .scrollContentBackground(.hidden).padding(7).background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Button("取消") { editorShown = false }.buttonStyle(TheaterActionStyle())
                            Spacer()
                            Button(saving ? "正在记下…" : "记住") { save() }.buttonStyle(TheaterActionStyle(prominent: true))
                                .disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 22)
                    TheaterRule()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filtered.isEmpty {
                            Text(query.isEmpty ? "把想让她记住的事，留在这里。" : "没有找到这段记忆。")
                                .font(.system(size: 15)).foregroundStyle(palette.secondary).padding(.vertical, 35)
                        }
                        ForEach(filtered) { memory in
                            VStack(alignment: .leading, spacing: 13) {
                                Text(memory.content).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 20) {
                                    Button("修改") { editingID = memory.id; content = memory.content; editorShown = true }
                                    Button("引用") { model.draft += (model.draft.isEmpty ? "" : "\n\n") + "> " + memory.content.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"; dismiss() }
                                    Spacer()
                                    Button("移入回收站") { Task { await model.removeMemory(memory) } }.foregroundStyle(palette.secondary)
                                }.font(.system(size: 12)).frame(minHeight: 36)
                            }.padding(.vertical, 22)
                            TheaterRule()
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 25)
                }
                if let notice = model.notice { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning).padding(18) }
            }.task { await model.refresh() }
        }
    }
    private func save() {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            await model.saveMemory(content: value, id: editingID)
            saving = false
            if model.memories.contains(where: { $0.content == value }) { content = ""; editingID = nil; editorShown = false }
        }
    }
}

struct MediaPanel: View {
    @ObservedObject var model: TheaterModel
    let onImport: () -> Void
    let onOpen: (Artifact) -> Void
    let onTranscribe: (Artifact) -> Void
    @Environment(\.theaterPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var filtered: [Artifact] { model.artifacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        TheaterPanel(title: "共享文件柜") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TextField("寻找文件", text: $query).font(.system(size: 15)).padding(12)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                    GlyphButton(label: "打开文件", glyph: .plus, action: onImport)
                }.padding(20)
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if filtered.isEmpty {
                            if query.isEmpty { Button("打开文件", action: onImport).buttonStyle(TheaterActionStyle()).padding(.top, 35) }
                            else { Text("没有找到这份文件。 ").font(.system(size: 15)).foregroundStyle(palette.secondary).padding(.top, 35) }
                        }
                        ForEach(filtered) { artifact in
                            VStack(alignment: .leading, spacing: 5) {
                                ArtifactRow(artifact: artifact, onOpen: { onOpen(artifact) })
                                    .contextMenu { if artifactIsAudio(artifact) { Button("转写这段录音") { onTranscribe(artifact) } } }
                                if artifactIsAudio(artifact) {
                                    Button("转写这段录音") { onTranscribe(artifact) }
                                        .font(.system(size: 12)).frame(minHeight: 34).padding(.leading, 57)
                                }
                                Button("围绕它继续问") { model.attach(artifact); dismiss() }
                                    .font(.system(size: 12)).frame(minHeight: 34).padding(.leading, 57)
                            }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 30)
                }
            }.task { await model.refresh() }
        }
    }
}

struct SearchPanel: View {
    @ObservedObject var model: TheaterModel
    let onSelect: () -> Void
    @Environment(\.theaterPalette) private var palette
    @FocusState private var searchFocused: Bool
    private var matchingMemories: [MemoryEntry] {
        guard !model.searchText.isEmpty else { return [] }
        return model.memories.filter { $0.content.localizedCaseInsensitiveContains(model.searchText) }
    }
    var body: some View {
        TheaterPanel(title: "寻找一页往事") {
            VStack(spacing: 0) {
                TextField("搜索对话与记忆", text: $model.searchText).font(.system(size: 17)).focused($searchFocused)
                    .padding(16).background(palette.raised, in: RoundedRectangle(cornerRadius: 13)).padding(20)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.conversations) { conversation in
                            Button {
                                Task { await model.selectConversation(conversation); onSelect() }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(conversation.title).font(.system(size: 16, weight: .medium))
                                    if let preview = conversation.preview { Text(preview).font(.system(size: 13)).foregroundStyle(palette.secondary).lineLimit(3) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 17).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            TheaterRule()
                        }
                        if !matchingMemories.isEmpty {
                            Text("记忆星空").font(.system(size: 13, weight: .medium)).foregroundStyle(palette.gold).padding(.top, 28).padding(.bottom, 8)
                            ForEach(matchingMemories) { memory in
                                Text(memory.content).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).padding(.vertical, 13)
                                TheaterRule()
                            }
                        }
                        if model.conversations.isEmpty && matchingMemories.isEmpty {
                            Text(model.searchText.isEmpty ? "还没有收录的乐章。" : "没有找到这一页。 ").font(.system(size: 15)).foregroundStyle(palette.secondary).padding(.vertical, 35)
                        }
                    }.padding(.horizontal, 26).padding(.bottom, 25)
                }
            }.onAppear { searchFocused = true }
        }
    }
}
