import SwiftUI

/// Shared by the Chat/Agent main surfaces and Settings.  Every control writes
/// through ChatViewModel, so both presentations observe the same persisted
/// profile instead of maintaining separate drafts.
struct ModelParameterEditor: View {
    @ObservedObject var viewModel: ChatViewModel
    let route: ModelParameterRoute
    let compact: Bool
    @State private var isAdvancedExpanded: Bool

    init(
        viewModel: ChatViewModel,
        route: ModelParameterRoute,
        compact: Bool = false
    ) {
        self.viewModel = viewModel
        self.route = route
        self.compact = compact
        _isAdvancedExpanded = State(initialValue: !compact)
    }

    private var profile: EffectiveModelParameterProfile {
        viewModel.effectiveModelParameters(for: route)
    }

    var body: some View {
        if route.modelID.isEmpty {
            ContentUnavailableView(
                "尚未選擇模型",
                systemImage: "slider.horizontal.3",
                description: Text("先選擇模型，LumaChat 才能建立獨立參數 Profile。")
            )
            .frame(minHeight: compact ? 160 : 220)
        } else {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                profileHeader
                quickControls
                Divider().opacity(0.55)
                advancedControls
            }
            .padding(compact ? 14 : 16)
            .frame(width: compact ? 440 : nil, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .task(id: route.key.storageKey) {
                await viewModel.refreshModelParameterCapabilities(for: route)
            }
        }
    }

    private var profileHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(route.modelID)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(profile.mode == .auto ? "AUTO" : "CUSTOM")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(profile.mode == .auto ? Color.green : LumaTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (profile.mode == .auto ? Color.green : LumaTheme.accent)
                                .opacity(0.12),
                            in: Capsule()
                        )
                }
                Text("\(route.provider.title) · \(route.backend.title) · \(profile.recommendationRule)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                viewModel.resetModelParametersToAuto(for: route)
            } label: {
                Label("恢復自動設定", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(profile.mode == .auto)
            .help("清除此模型的完整 Custom override，並重新套用最新推薦值")
        }
    }

    private var quickControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 11) {
            GridRow {
                parameterLabel("Context", icon: "rectangle.expand.vertical")
                HStack(spacing: 7) {
                    TextField(
                        "Context",
                        value: intBinding(\.contextWindowTokens),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 104)
                    Text("tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                parameterLabel("Max Output", icon: "text.append")
                HStack(spacing: 7) {
                    TextField(
                        "Max Output",
                        value: intBinding(\.maxOutputTokens),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 104)
                    Text("tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                parameterLabel("Thinking", icon: "brain.head.profile")
                HStack {
                    Toggle("啟用", isOn: boolBinding(\.thinkingEnabled))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!profile.capabilities.supportsThinking)
                    Text(profile.capabilities.supportsThinking ? "啟用模型思考" : "此 backend/model 不支援")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                parameterLabel("Reasoning", icon: "gauge.with.dots.needle.33percent")
                if profile.capabilities.supportsReasoningEffort {
                    Picker("Reasoning Effort", selection: effortBinding) {
                        ForEach(profile.capabilities.supportedReasoningEfforts) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                } else {
                    Text("此 backend/model 不支援 reasoning_effort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            Text(
                "Backend 上限 \(tokenLabel(profile.capabilities.backendMaximumContextTokens)) · "
                    + "模型上限 \(tokenLabel(profile.capabilities.modelMaximumContextTokens)) · "
                    + "有效 \(tokenLabel(profile.effectiveContextTokens))"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .offset(y: 20)
        }
        .padding(.bottom, 10)
    }

    private var advancedControls: some View {
        DisclosureGroup("進階參數", isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 13) {
                if profile.capabilities.supportsTemperature {
                    sliderRow(
                        title: "Temperature",
                        value: doubleBinding(\.temperature),
                        range: 0...2,
                        step: 0.05
                    )
                }
                if profile.capabilities.supportsTopP {
                    sliderRow(
                        title: "Top P",
                        value: doubleBinding(\.topP),
                        range: 0...1,
                        step: 0.01
                    )
                }
                if profile.capabilities.supportsTopK {
                    integerRow(title: "Top K", value: intBinding(\.topK))
                }
                if profile.capabilities.supportsMinP {
                    sliderRow(
                        title: "Min P",
                        value: doubleBinding(\.minP),
                        range: 0...1,
                        step: 0.01
                    )
                }
                if profile.capabilities.supportsRepetitionPenalty {
                    sliderRow(
                        title: "Repetition Penalty",
                        value: doubleBinding(\.repetitionPenalty),
                        range: 0...2,
                        step: 0.01
                    )
                }
                if profile.capabilities.supportsPresencePenalty {
                    sliderRow(
                        title: "Presence Penalty",
                        value: doubleBinding(\.presencePenalty),
                        range: -2...2,
                        step: 0.05
                    )
                }
                Toggle("Preserve Thinking", isOn: boolBinding(\.preserveThinking))
                    .disabled(!profile.capabilities.supportsPreserveThinking)
                if !profile.capabilities.supportsPreserveThinking {
                    Text("目前 provider contract 不安全支援跨輪重送 hidden thinking，因此此欄位不會送入 API。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)
        }
        .font(.callout.weight(.medium))
    }

    private func parameterLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 126, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.caption.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func integerRow(title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 126, alignment: .leading)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            Spacer()
        }
    }

    private func intBinding(
        _ keyPath: WritableKeyPath<ModelParameterValues, Int>
    ) -> Binding<Int> {
        Binding(
            get: { profile.values[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateModelParameters(for: route) {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func doubleBinding(
        _ keyPath: WritableKeyPath<ModelParameterValues, Double>
    ) -> Binding<Double> {
        Binding(
            get: { profile.values[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateModelParameters(for: route) {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func boolBinding(
        _ keyPath: WritableKeyPath<ModelParameterValues, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { profile.values[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateModelParameters(for: route) {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var effortBinding: Binding<ModelReasoningEffort> {
        Binding(
            get: { profile.values.reasoningEffort },
            set: { newValue in
                viewModel.updateModelParameters(for: route) {
                    $0.reasoningEffort = newValue
                }
            }
        )
    }

    private func tokenLabel(_ value: Int) -> String {
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000)
                .formatted(.number.precision(.fractionLength(0...1))) + "M"
        }
        if value >= 1_024 { return "\(value / 1_024)K" }
        return value.formatted()
    }
}
