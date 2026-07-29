import AppKit
import ServiceManagement
import SwiftUI

extension PromptMeetSettingsView {
    var capturePane: some View {
        settingsGroup("采集与权限") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("包含本机麦克风", isOn: $includeLocalMicrophone)
                    .toggleStyle(.switch)
                Text(
                    includeLocalMicrophone
                        ? "下次会议会请求并采集麦克风。系统音频仍保持独立。"
                        : "下次会议不会请求麦克风权限或启动 AVAudioEngine，只采集系统音频。"
                )
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(includeLocalMicrophone ? VisualTokens.secondaryText : VisualTokens.amber)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动摘要与待办")
                            .font(.system(size: 11, weight: .semibold))
                        Text("按有效录音时间触发；暂停不计时，没有新输入时不会调用模型")
                            .font(.system(size: 9))
                            .foregroundStyle(VisualTokens.secondaryText)
                    }
                    Spacer()
                    Picker("自动摘要与待办", selection: summaryCadenceBinding) {
                        ForEach(SummaryCadence.allCases, id: \.rawValue) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .tint(VisualTokens.primaryText)
                }
            }
            .padding(12)
            .background(VisualTokens.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            permissionRow("屏幕与系统音频", detail: "ScreenCaptureKit，不需要 BlackHole") {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            Divider().overlay(VisualTokens.line)
            permissionRow("麦克风", detail: "AVAudioEngine 使用当前默认输入设备") {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            Divider().overlay(VisualTokens.line)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地转写")
                        .font(.system(size: 11, weight: .semibold))
                    Text("whisper.cpp · 音频不会离开本机")
                        .font(.system(size: 10))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
                Spacer()
                Picker("语言", selection: $modelLibrary.language) {
                    Text("自动").tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .labelsHidden()
                .frame(width: 105)
                Button {
                    NSWorkspace.shared.open(modelLibrary.repository.modelsDirectory)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
            }
            HStack {
                Toggle("实时翻译", isOn: $modelLibrary.translationEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Picker("目标语言", selection: $modelLibrary.translationTargetLanguage) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .disabled(!modelLibrary.translationEnabled)
                .frame(width: 150)
            }
            VStack(spacing: 6) {
                ForEach(WhisperModelCatalog.models) { model in
                    modelRow(model)
                }
            }
            if let message = modelLibrary.errorMessage {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(VisualTokens.danger)
                    .lineLimit(2)
            }
        }
    }

    func modelRow(_ model: WhisperModelDescriptor) -> some View {
        let installed = modelLibrary.isInstalled(model)
        let selected = installed && modelLibrary.selectedModelID == model.id
        let downloading = modelLibrary.downloadingModelID == model.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.sizeLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
                Text(model.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(VisualTokens.secondaryText)
                if downloading {
                    ProgressView(value: modelLibrary.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(VisualTokens.cobalt)
                }
            }
            Spacer()
            modelActions(model, installed: installed, selected: selected, downloading: downloading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(VisualTokens.raised.opacity(selected ? 1 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    func modelActions(
        _ model: WhisperModelDescriptor,
        installed: Bool,
        selected: Bool,
        downloading: Bool
    ) -> some View {
        if downloading {
            Button("取消") { modelLibrary.cancelDownload() }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
        } else if selected {
            Label("使用中", systemImage: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VisualTokens.live)
        } else if installed {
            Button("使用") { modelLibrary.select(model) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                modelLibrary.remove(model)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(VisualTokens.secondaryText)
        } else {
            Button("下载") { modelLibrary.download(model) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(modelLibrary.downloadingModelID != nil)
        }
    }

}
