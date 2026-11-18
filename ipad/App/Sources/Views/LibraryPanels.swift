import SwiftUI

struct TheaterPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        NavigationStack {
            content().foregroundStyle(palette.text)
                .background {
                    ZStack {
                        palette.background
                    }.ignoresSafeArea()
                }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(palette.background, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(title).font(.theaterSerif(17)).tracking(1).accessibilityAddTraits(.isHeader)
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.foregroundStyle(palette.rose) }
                }
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
                    HStack(spacing: 14) {
                        CameoPortrait(image: model.isConnected ? "happy_achieved" : "idle_gentle", size: 58, online: model.isConnected)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.isConnected ? "灯亮着，我在这里。" : "把琴房的钥匙交给我吧。").font(.theaterSerif(17, weight: .medium))
                            Text("口令只保存在这台 iPad 的钥匙串里，不会写进网址。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }
                    }.padding(.vertical, 6)
                }.listRowBackground(Color.clear)
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
                }.listRowBackground(palette.letter)
                Section {
                    Button {
                        Task {
                            await model.connect(token: token)
                            if model.isConnected { token = ""; dismiss() }
                        }
                    } label: {
                        HStack { Text("连接电脑"); Spacer(); if model.connection == .connecting { ProgressView() } }
                    }.disabled(model.connection == .connecting || token.isEmpty || model.deviceID.isEmpty)
                        .foregroundStyle(palette.rose)
                    Button("使用已保存的配对") {
                        Task { await model.reconnect(); if model.isConnected { dismiss() } }
                    }.disabled(model.connection == .connecting)
                    if model.isConnected { Button("断开连接") { model.disconnect() } }
                }.listRowBackground(palette.letter)
                if let notice = model.notice {
                    Section { Text(notice).foregroundStyle(palette.warning).font(.system(size: 14)) }.listRowBackground(palette.letter)
                }
            }.scrollContentBackground(.hidden).tint(palette.rose)
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
                Section {
                    HStack(spacing: 14) {
                        CameoPortrait(image: "idle_gentle", size: 58)
                        VStack(alignment: .leading, spacing: 3) {
                            ScriptLine(text: "Just for you", size: 24)
                            Text("调一调她说话的样子").font(.theaterSerif(17))
                            Text("无论怎么调，她都还是她。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }
                    }.padding(.vertical, 6)
                }.listRowBackground(Color.clear)
                Section("琴房的光线") {
                    choiceRow("昼夜", values: [("随系统", "auto"), ("春日影", "day"), ("月下琴房", "night")], selection: value(\.theme))
                    choiceRow("透视度", values: [("伴侣纯净", "companion"), ("智能平衡", "balanced"), ("完整记录", "studio")], selection: value(\.transparency))
                }.listRowBackground(palette.letter)
                Section("灵魂调律") {
                    personalitySlider("端庄与温柔", lower: "卸下防备", upper: "端庄严谨", keyPath: \.formality)
                    personalitySlider("讲述分寸", lower: "克制留白", upper: "事无巨细", keyPath: \.detail)
                    personalitySlider("轻嗔浓度", lower: "坦率温和", upper: "傲娇俏皮", keyPath: \.teasing)
                }.listRowBackground(palette.letter)
                Section("声音") {
                    Toggle("琴音微仪式", isOn: Binding(get: { (edited ?? model.settings).sound }, set: { enabled in
                        var updated = edited ?? model.settings; updated.sound = enabled; edited = updated
                        var saved = model.settings; saved.sound = enabled
                        Task { await model.saveSettings(saved) }
                    }))
                    Toggle("窗边雨声", isOn: $ambienceEnabled)
                    if audio.isSpeaking { Button("停止朗读") { audio.stopSpeech() } }
                    if let notice = audio.notice { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning) }
                }.listRowBackground(palette.letter)
                Section {
                    Button {
                        model.notice = nil
                        Task { await model.saveSettings(edited ?? model.settings); if model.notice == nil { dismiss() } }
                    } label: {
                        Text("就这样，记住这些").foregroundStyle(palette.rose)
                    }
                }.listRowBackground(palette.letter)
                Section("我的琴房") {
                    Button("电脑连接", action: onConnect)
                    Button {
                        exporting = true
                        Task { exportURL = await model.exportLibrary(); exporting = false }
                    } label: {
                        HStack { Text("导出全部记忆与原件"); Spacer(); if exporting { ProgressView() } }
                    }.disabled(exporting || !model.isConnected)
                    if let exportURL { ShareLink(item: exportURL) { Text("保存导出的档案") } }
                }.listRowBackground(palette.letter)
                if let notice = model.notice {
                    Section { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning) }.listRowBackground(palette.letter)
                }
            }.scrollContentBackground(.hidden).tint(palette.rose).onAppear { edited = model.settings }
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
                        Text(item.0).font(.system(size: 13, weight: selection.wrappedValue == item.1 ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(selection.wrappedValue == item.1 ? palette.raised : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                            .shadow(color: selection.wrappedValue == item.1 ? palette.shadow : .clear, radius: 5, x: 0, y: 2)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(selection.wrappedValue == item.1 ? palette.text : palette.secondary)
                        .accessibilityLabel(title + "，" + item.0)
                        .accessibilityValue(selection.wrappedValue == item.1 ? "已选中" : "")
                }
            }.padding(4).background(palette.sunken, in: RoundedRectangle(cornerRadius: 14))
        }.padding(.vertical, 5)
    }
    private func personalitySlider(_ title: String, lower: String, upper: String, keyPath: WritableKeyPath<Personality, Int>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15))
                Spacer()
                Text("\((edited ?? model.settings).personality[keyPath: keyPath])%").font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.dim)
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
                ScriptLine(text: "Little things about you", size: 26).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 14)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TheaterGlyph(kind: .search).stroke(lineWidth: 1.3).frame(width: 17, height: 17).foregroundStyle(palette.dim)
                        TextField("寻找一段记忆", text: $query).font(.system(size: 15))
                    }.padding(.horizontal, 14).frame(height: 42)
                        .background(palette.sunken, in: RoundedRectangle(cornerRadius: 12))
                    Button("记下一件事") { content = ""; editingID = nil; editorShown = true }
                        .buttonStyle(TheaterActionStyle(prominent: true))
                }.padding(20)
                if editorShown {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(editingID == nil ? "一件想让她记住的事" : "重新写下这件事").font(.theaterSerif(18))
                        TextEditor(text: $content).font(.system(size: 16)).frame(minHeight: 100, maxHeight: 180)
                            .scrollContentBackground(.hidden).padding(9).background(palette.sunken, in: RoundedRectangle(cornerRadius: 14))
                        HStack {
                            Button("取消") { editorShown = false }.buttonStyle(TheaterActionStyle())
                            Spacer()
                            Button(saving ? "正在记下…" : "收进记忆") { save() }.buttonStyle(TheaterActionStyle(prominent: true))
                                .disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(20).letterCard(cornerRadius: 18).padding(.horizontal, 20).padding(.bottom, 18)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if filtered.isEmpty {
                            VStack(spacing: 8) {
                                FiligreeDivider(width: 120).padding(.bottom, 6)
                                Text(query.isEmpty ? "慢慢认识你。" : "没有找到这段记忆。").font(.theaterSerif(18))
                                if query.isEmpty {
                                    Text("想让她记住的事，由你亲手写下。").font(.system(size: 13)).foregroundStyle(palette.secondary)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, memory in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(String(format: "%02d", index + 1)).font(.theaterSerif(14)).foregroundStyle(palette.gold).frame(width: 26, alignment: .leading)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(memory.content).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    HStack(spacing: 20) {
                                        Button("重新写") { editingID = memory.id; content = memory.content; editorShown = true }
                                        Button("引用到草稿") { model.draft += (model.draft.isEmpty ? "" : "\n\n") + "> " + memory.content.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"; dismiss() }
                                        Spacer()
                                        Button("移入回收站") { Task { await model.removeMemory(memory) } }.foregroundStyle(palette.dim)
                                    }.font(.system(size: 13)).foregroundStyle(palette.rose).frame(minHeight: 36)
                                }
                            }.padding(.horizontal, 18).padding(.vertical, 14)
                                .letterCard(cornerRadius: 16)
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
                ScriptLine(text: "Treasures", size: 26).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 14)
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        TheaterGlyph(kind: .search).stroke(lineWidth: 1.3).frame(width: 17, height: 17).foregroundStyle(palette.dim)
                        TextField("寻找一份珍藏", text: $query).font(.system(size: 15))
                    }.padding(.horizontal, 14).frame(height: 42)
                        .background(palette.sunken, in: RoundedRectangle(cornerRadius: 12))
                    Button(action: onImport) {
                        HStack(spacing: 6) { TheaterGlyph(kind: .plus).stroke(lineWidth: 1.5).frame(width: 13, height: 13); Text("收进文件") }
                    }.buttonStyle(TheaterActionStyle(prominent: true))
                }.padding(20)
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if filtered.isEmpty {
                            VStack(spacing: 12) {
                                Image("icon_archive").resizable().scaledToFit().frame(width: 84, height: 84)
                                Text(query.isEmpty ? "纸页、原音、画面，都可以交给我。" : "没有找到这份文件。").font(.theaterSerif(16)).foregroundStyle(palette.secondary)
                                if query.isEmpty { Button("打开文件", action: onImport).buttonStyle(TheaterActionStyle()) }
                            }.padding(.top, 35)
                        }
                        ForEach(filtered) { artifact in
                            VStack(alignment: .leading, spacing: 5) {
                                ArtifactRow(artifact: artifact, onOpen: { onOpen(artifact) })
                                    .contextMenu { if artifactIsAudio(artifact) { Button("转写这段录音") { onTranscribe(artifact) } } }
                                HStack(spacing: 18) {
                                    if artifactIsAudio(artifact) {
                                        Button("转写这段录音") { onTranscribe(artifact) }
                                    }
                                    Button("围绕它继续问") { model.attach(artifact); dismiss() }
                                }.font(.system(size: 12)).foregroundStyle(palette.rose).frame(minHeight: 34).padding(.leading, 62)
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
                HStack(spacing: 10) {
                    TheaterGlyph(kind: .search).stroke(lineWidth: 1.4).frame(width: 19, height: 19).foregroundStyle(palette.dim)
                    TextField("寻找一段回忆或记忆", text: $model.searchText).font(.system(size: 17)).focused($searchFocused)
                }.padding(.horizontal, 16).frame(height: 48)
                    .background(palette.sunken, in: RoundedRectangle(cornerRadius: 12))
                    .padding(20)
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
                            TheaterEyebrow(text: "记忆").padding(.top, 28).padding(.bottom, 8)
                            ForEach(matchingMemories) { memory in
                                Text(memory.content).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).padding(.vertical, 13)
                                TheaterRule()
                            }
                        }
                        if model.conversations.isEmpty && matchingMemories.isEmpty {
                            Text(model.searchText.isEmpty ? "还没有收录的乐章。" : "还没找到这一页。换个词试试？").font(.theaterSerif(15)).foregroundStyle(palette.secondary).padding(.vertical, 35)
                        }
                    }.padding(.horizontal, 26).padding(.bottom, 25)
                }
            }.onAppear { searchFocused = true }
        }
    }
}
