import SwiftUI

struct ModelPanel: View {
    @ObservedObject var model: TheaterModel
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        TheaterPanel(title: "模型与思考") {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    CameoPortrait(image: "thinking_deep", size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        TheaterEyebrow(text: "琴房的演奏者")
                        Text("今天，请谁来弹？").font(.theaterSerif(19))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("要想得多深一点").font(.system(size: 13, weight: .medium)).foregroundStyle(palette.secondary)
                    HStack(spacing: 6) {
                        ForEach(model.availableEfforts, id: \.self) { effort in
                            Button(effortLabel(effort)) { model.selectedEffort = effort }
                                .buttonStyle(TheaterActionStyle(prominent: model.selectedEffort == effort))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("透视度").font(.system(size: 13, weight: .medium)).foregroundStyle(palette.secondary)
                    HStack(spacing: 6) {
                        ForEach(["companion", "balanced", "studio"], id: \.self) { mode in
                            Button(["companion": "伴侣纯净", "balanced": "智能平衡", "studio": "完整记录"][mode]!) {
                                var settings = model.settings; settings.transparency = mode
                                Task { await model.saveSettings(settings) }
                            }.buttonStyle(TheaterActionStyle(prominent: model.settings.transparency == mode))
                        }
                    }
                }
                StitchRule()
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.models.isEmpty {
                            Text("接通琴房后，这里会列出可用的模型。").font(.system(size: 14)).foregroundStyle(palette.secondary)
                        }
                        ForEach(model.models) { item in
                            Button { model.selectedModelID = item.id } label: {
                                HStack(spacing: 12) {
                                    Text(item.name).font(.system(size: 15)).multilineTextAlignment(.leading)
                                    Spacer()
                                    if model.selectedModelID == item.id { Circle().fill(palette.rose).frame(width: 6, height: 6) }
                                }.padding(.horizontal, 16).frame(minHeight: 50)
                                    .background(model.selectedModelID == item.id ? palette.sunken : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(palette.text)
                                .accessibilityValue(model.selectedModelID == item.id ? "已选中" : "")
                        }
                    }
                }
            }.padding(24)
        }
    }
}
