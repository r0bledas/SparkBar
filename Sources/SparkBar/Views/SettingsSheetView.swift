import SwiftUI

public struct SettingsSheetView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyInput: String = ""
    @State private var modelInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var showSavedToast: Bool = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let nsImage = NSImage(contentsOf: iconURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                Text("SparkBar Settings")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") {
                    saveCurrentProviderFields()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Provider Picker (Moved into Settings, default DeepSeek)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default AI Provider")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Picker("Provider", selection: $settings.selectedProvider) {
                            ForEach(LLMProviderType.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: settings.selectedProvider) { _, newProvider in
                            loadFields(for: newProvider)
                        }

                        Toggle("Show AI Provider picker in the main floating bar", isOn: $settings.showProviderInMainBar)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    // API Key Field
                    if settings.selectedProvider.requiresAPIKey {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(settings.selectedProvider.displayName) API Key")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !apiKeyInput.isEmpty {
                                    Label("Key Configured", systemImage: "checkmark.seal.fill")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.green)
                                }
                            }

                            HStack(spacing: 8) {
                                SecureField("sk-...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .onSubmit {
                                        saveCurrentProviderFields()
                                    }

                                Button("Save & Fetch Models") {
                                    saveCurrentProviderFields()
                                }
                            }
                        }
                    }

                    // Dynamic API Models Selection
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Active Model (Dynamically Fetched from API `/models`)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task {
                                    await settings.refreshModelsForCurrentProvider()
                                    modelInput = settings.currentModel
                                }
                            } label: {
                                Label(settings.isFetchingModels ? "Fetching…" : "Refresh API Models", systemImage: "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.link)
                        }

                        HStack(spacing: 8) {
                            TextField("Model ID (fetched from API)", text: $modelInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: modelInput) { _, newValue in
                                    settings.currentModel = newValue
                                }

                            if !settings.availableModels.isEmpty {
                                Menu("API Models (\(settings.availableModels.count))") {
                                    ForEach(settings.availableModels) { m in
                                        Button(m.displayLabel) {
                                            modelInput = m.id
                                            settings.currentModel = m.id
                                        }
                                    }
                                }
                                .frame(width: 150)
                            }
                        }
                    }

                    // Reasoning Effort Level (Dynamically populated from API `/models`)
                    let levels = settings.supportedEffortLevelsForCurrentModel
                    if !levels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Thinking Effort (Dynamic from API)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("Thinking Effort", selection: $settings.reasoningEffort) {
                                ForEach(levels, id: \.self) { level in
                                    Text(settings.effortDisplayLabel(for: level)).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    // Endpoint URL
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("API Base URL")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset Default") {
                                baseURLInput = settings.selectedProvider.defaultBaseURL
                                settings.currentBaseURL = baseURLInput
                                Task {
                                    await settings.refreshModelsForCurrentProvider()
                                    modelInput = settings.currentModel
                                }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }

                        TextField("https://api.deepseek.com/v1", text: $baseURLInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: baseURLInput) { _, newValue in
                                settings.currentBaseURL = newValue
                            }
                    }

                    Divider()

                    // Agent Tools & Capabilities (Hermes / OpenCode engine)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Agent Tools & Web Search (Hermes / OpenCode Engine)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Toggle("Enable Function Calling & Autonomous Tools", isOn: $settings.enableTools)
                            .font(.system(size: 13))

                        if settings.enableTools {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Web Search & URL Reader (`web_search`, `fetch_url`)", isOn: $settings.enableWebSearchTool)
                                Toggle("Terminal Command Runner (`run_command`)", isOn: $settings.enableTerminalTool)
                                Toggle("File System Access (`read_file`, `write_file`, `list_directory`)", isOn: $settings.enableFileTools)
                                Toggle("Clipboard Integration (`clipboard`)", isOn: $settings.enableClipboardTool)
                            }
                            .font(.system(size: 12))
                            .padding(.leading, 14)
                        }

                        Toggle("Enable Server-Side Web Search", isOn: $settings.enableServerSideSearch)
                            .font(.system(size: 13))
                    }

                    Divider()

                    // Window Behavior & Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Window & Shortcut")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Global Toggle Shortcut:")
                                .font(.system(size: 12))
                            Text("⌥ Space (Option + Space)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }

                        Toggle("Keep window pinned when clicking outside", isOn: $settings.pinWindowOnBlur)
                            .font(.system(size: 13))

                        Toggle("Open SparkBar automatically on startup", isOn: $settings.openOnStartup)
                            .font(.system(size: 13))

                        Toggle("Show SparkBar icon in the menu bar", isOn: $settings.showMenuBarIcon)
                            .font(.system(size: 13))
                    }
                }
                .padding(.trailing, 4)
            }

            if showSavedToast {
                Text("Saved configuration & refreshed API models!")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 540, height: 540)
        .onAppear {
            loadFields(for: settings.selectedProvider)
        }
    }

    private func loadFields(for provider: LLMProviderType) {
        apiKeyInput = settings.apiKey(for: provider)
        modelInput = settings.currentModel
        baseURLInput = settings.customEndpoints[provider.rawValue] ?? provider.defaultBaseURL
    }

    private func saveCurrentProviderFields() {
        settings.setAPIKey(apiKeyInput, for: settings.selectedProvider)
        if !modelInput.isEmpty {
            settings.currentModel = modelInput
        }
        settings.currentBaseURL = baseURLInput
        showSavedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showSavedToast = false
        }
    }
}
