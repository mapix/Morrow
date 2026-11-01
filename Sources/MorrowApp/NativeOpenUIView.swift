import SwiftUI
import MorrowCore

/// The OpenUI Lang native profile. Rendering never performs host actions.
struct NativeOpenUIView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let interaction: OpenUIInteraction
    @EnvironmentObject var model: AppModel
    @State private var values: [String: OpenUIJSON]
    @State private var revision: Int
    @State private var busy = false
    @State private var error: String?
    init(interaction: OpenUIInteraction) { self.interaction = interaction; _values = State(initialValue: interaction.values); _revision = State(initialValue: interaction.stateRevision) }
    private var current: OpenUIInteraction { model.openUIInteractions.first { $0.id == interaction.id } ?? interaction }
    private var program: OpenUIProgram? { try? OpenUILang.parse(current.source) }
    private var root: OpenUIValue? { try? program?.root(state: values) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let root { render(root, form: nil, contained: false) }
            else { Text(L10n.t("这次结构化交互暂时无法显示，可以用下方输入继续。")).font(Theme.body).foregroundStyle(Theme.secondary) }
            if let receipt = current.receipt {
                if let completedAt = current.completedAt {
                    Text(L10n.t("首次保存时（") + completedAt.uiFormatted(date: .abbreviated, time: .shortened) + "）：" + receipt).font(Theme.body).foregroundStyle(Theme.secondary).textSelection(.enabled)
                } else { Text(receipt).font(Theme.body).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            }
            if let error { Text(error).font(Theme.body).foregroundStyle(Theme.error).textSelection(.enabled) }
        }.disabled(busy || current.messageStatus != "completed")
            .onChange(of: current.stateRevision) { if current.stateRevision > revision { values = current.values; revision = current.stateRevision } }
    }
    private func render(_ value: OpenUIValue, form: String?, contained: Bool) -> AnyView {
        guard case .node(let node) = value else { return AnyView(Text(value.text).font(Theme.body).foregroundStyle(Theme.secondary)) }
        func arg(_ index: Int) -> OpenUIValue { index < node.arguments.count ? node.arguments[index] : .json(.null) }
        func children(_ values: [OpenUIValue], form: String?, contained: Bool) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 16) { ForEach(Array(values.enumerated()), id: \.offset) { _, child in render(child, form: form, contained: contained) } }.frame(maxWidth: .infinity, alignment: .leading))
        }
        switch node.name {
        case "Stack": return children(arg(0).children, form: form, contained: contained)
        case "Card":
            let content = children(arg(0).children, form: form, contained: true)
            return contained ? content : AnyView(content.padding(20).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.rule)))
        case "Form": return children(arg(1).children, form: arg(0).text, contained: contained)
        case "CardHeader": return AnyView(VStack(alignment: .leading, spacing: 8) { Text(arg(0).text).font(Theme.heading); if !arg(1).text.isEmpty { Text(arg(1).text).font(Theme.body).foregroundStyle(Theme.secondary) } })
        case "TextContent", "Text": return AnyView(Text(arg(0).text).font(arg(1).text.contains("large") ? Theme.heading : Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled))
        case "Markdown": return AnyView(WorkMarkdownContent(text: arg(0).text))
        case "Table": return AnyView(OpenUITable(columns: arg(0).children))
        case "BarChart", "LineChart", "PieChart":
            if let data = try? OpenUIChartData(node: node) { return AnyView(OpenUIChartView(kind: node.name, data: data)) }
            return AnyView(Text(L10n.t("图表数据无效，未绘制。")).foregroundStyle(Theme.secondary))
        case "Steps": return AnyView(OpenUIStepsView(title: arg(0).text, items: arg(1).children.map(\.text)))
        case "FormControl":
            if current.completedAt != nil, case .node(let child) = arg(1), ["Input", "TextArea"].contains(child.name) {
                return AnyView(HStack(alignment: .top, spacing: 16) {
                    Text(arg(0).text).font(Theme.label).foregroundStyle(Theme.secondary).frame(width: 92, alignment: .leading)
                    render(arg(1), form: form, contained: contained)
                })
            }
            if case .node(let child) = arg(1), child.name == "Choice" { return render(arg(1), form: form, contained: contained) }
            return AnyView(VStack(alignment: .leading, spacing: 7) { Text(arg(0).text).font(Theme.label).foregroundStyle(Theme.secondary); render(arg(1), form: form, contained: contained) })
        case "Input", "TextArea":
            let binding = fieldBinding(name: arg(0).text, defaultValue: arg(2), form: form)
            if current.completedAt != nil { return AnyView(OpenUIRecordValue(value: binding.wrappedValue)) }
            if node.name == "TextArea" { return AnyView(OpenUITextArea(text: binding, name: arg(0).text)) }
            return AnyView(TextField(arg(1).text, text: binding).textFieldStyle(PaperFieldStyle()).accessibilityLabel(arg(0).text))
        case "Choice":
            let options = choices(arg(2)); let binding = fieldBinding(name: arg(0).text, defaultValue: arg(3), form: form)
            if current.completedAt != nil {
                return AnyView(HStack(alignment: .top, spacing: 16) {
                    Text(arg(1).text).font(Theme.label).foregroundStyle(Theme.secondary).frame(width: 92, alignment: .leading)
                    OpenUIRecordValue(value: options.first(where: { $0.value == binding.wrappedValue })?.label ?? binding.wrappedValue)
                })
            }
            return AnyView(VStack(alignment: .leading, spacing: 8) { Text(arg(1).text).font(Theme.label).foregroundStyle(Theme.secondary); Picker(arg(1).text, selection: binding) { ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) } }.pickerStyle(.menu).labelsHidden().accessibilityLabel(arg(1).text) })
        case "Buttons":
            return AnyView(HStack(spacing: 14) { ForEach(Array(arg(0).children.enumerated()), id: \.offset) { _, child in render(child, form: form, contained: contained) }; Spacer(minLength: 0) })
        case "Button":
            if current.completedAt != nil { return AnyView(EmptyView()) }
            let actions = arg(1).actions; let primary = arg(2).text == "primary"
            return AnyView(OpenUIActionButton(label: arg(0).text, primary: primary) { submit(actions, form: form, buttonLabel: arg(0).text) }.disabled(actions.isEmpty))
        case "Citation":
            if current.completedAt != nil { return AnyView(OpenUIRecordValue(value: arg(1).text.isEmpty ? L10n.t("原邮件引用") : arg(1).text)) }
            return AnyView(Button(arg(1).text.isEmpty ? L10n.t("查看原邮件") : arg(1).text) { submit([OpenUIAction(name: "OpenMailSource", arguments: [arg(0)])], form: form, buttonLabel: L10n.t("查看原邮件")) }.buttonStyle(QuietButtonStyle()))
        default: return AnyView(Text(L10n.t("这项原生交互暂不可用。")).font(Theme.label).foregroundStyle(Theme.secondary))
        }
    }
    private func choices(_ value: OpenUIValue) -> [(label: String, value: String)] {
        value.children.map { item in let object = (try? item.json().object) ?? [:]; if !object.isEmpty { return (object["label"]?.text ?? object["value"]?.text ?? "", object["value"]?.text ?? "") }; return (item.text, item.text) }
    }
    private func fieldBinding(name: String, defaultValue: OpenUIValue, form: String?) -> Binding<String> {
        let key = (form ?? "page") + ":" + name
        return Binding(get: { values[key]?.text ?? defaultValue.text }, set: { text in
            let bindingName: String?
            if case .binding(let stateName, _) = defaultValue { bindingName = stateName } else { bindingName = nil }
            if let page = model.editOpenUIField(.string(text), key: key, interactionID: interaction.id, bindingName: bindingName) { values = page.values; revision = page.stateRevision }

        })
    }
    private func fields(_ root: OpenUIValue, scope: String?) -> [String: [String: OpenUIFieldState]] {
        var result: [String: [String: OpenUIFieldState]] = [:]
        func walk(_ value: OpenUIValue, form: String?) {
            guard case .node(let node) = value else { if case .array(let array) = value { for child in array { walk(child, form: form) } }; return }
            let nextForm = node.name == "Form" ? node.arguments.first?.text : form
            if ["Input", "TextArea", "Choice"].contains(node.name), let name = node.arguments.first?.text {
                let owner = nextForm ?? "page"; let index = node.name == "Choice" ? 3 : 2
                let fallback = index < node.arguments.count ? (try? node.arguments[index].json()) ?? .null : .null
                result[owner, default: [:]][name] = OpenUIFieldState(value: values[owner + ":" + name] ?? fallback, componentType: node.name == "Choice" ? "select" : node.name == "TextArea" ? "textarea" : "input")
            }
            for child in node.arguments { if case .node = child { walk(child, form: nextForm) }; if case .array = child { walk(child, form: nextForm) } }
        }
        walk(root, form: nil)
        if let scope { return result[scope].map { [scope: $0] } ?? [:] }; return result
    }
    private func validate(_ value: OpenUIValue, form target: String?) throws {
        func walk(_ value: OpenUIValue, owner: String?) throws {
            guard case .node(let node) = value else { for child in value.children { try walk(child, owner: owner) }; return }
            let nextOwner = node.name == "Form" ? node.arguments.first?.text : owner
            if node.name == "Form", let target, nextOwner != target { return }
            if ["Input", "TextArea"].contains(node.name), node.arguments.count > 3 {
                let rules = (try? node.arguments[3].json().object) ?? [:]; let name = node.arguments[0].text
                let text = values[(nextOwner ?? "page") + ":" + name]?.text ?? node.arguments[2].text
                if rules["required"]?.truth == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OpenUIError.message(L10n.t("请填写：") + name) }
                if rules["email"]?.truth == true && !text.isEmpty && !(name == "sender" ? (!MailResponder.parseAllowlist(text).isEmpty && MailResponder.parseAllowlist(text).allSatisfy(MailResponder.validSender)) : MailAddress.isValid(text)) { throw OpenUIError.message(L10n.t("邮箱地址格式无效：") + name) }
                if case .number(let length) = rules["minLength"], Double(text.count) < length { throw OpenUIError.message(L10n.t("内容太短：") + name) }
            }
            for child in node.arguments { try walk(child, owner: nextOwner) }
        }
        try walk(value, owner: nil)
    }
    private func submit(_ actions: [OpenUIAction], form: String?, buttonLabel: String) {
        if current.stateRevision > revision { values = current.values; revision = current.stateRevision }
        guard !busy, current.completedAt == nil, let root else { return }
        do { if !buttonLabel.contains("取消") { try validate(root, form: form) } } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; let formState = fields(root, scope: form)
        let sessionID = current.sessionID ?? model.activeSessionID
        Task {
            await ChatTaskContext.$sessionID.withValue(sessionID) {
            defer { busy = false }
            await model.saveOpenUIValues(values, interactionID: interaction.id, revision: revision)
            for action in actions {
                let event: OpenUIActionEvent
                if action.name == "ToAssistant" { event = OpenUIActionEvent(type: "continue_conversation", humanFriendlyMessage: action.arguments.first?.text ?? buttonLabel, params: action.arguments.count > 1 ? ["context": (try? action.arguments[1].json()) ?? .null] : [:], formName: form, formState: formState) }
                else {
                    var params: [String: OpenUIJSON] = [:]; for (i, name) in (OpenUINativeLibrary.actions[action.name] ?? []).enumerated() where i < action.arguments.count { params[name] = try? action.arguments[i].json() }
                    event = OpenUIActionEvent(type: action.name, params: params, formName: form, formState: formState)
                }
                do { try await model.handleOpenUIAction(event, interactionID: interaction.id, buttonLabel: buttonLabel); if model.openUIInteractions.first(where: { $0.id == interaction.id })?.completedAt != nil { break } }
                catch { self.error = error.localizedDescription; break }
            }
            }
        }
    }
}

private struct OpenUITable: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var columns: [OpenUIValue]
    private var data: [(label: String, cells: [OpenUIValue])] { columns.compactMap { if case .node(let node) = $0, node.name == "Col", node.arguments.count >= 2 { return (node.arguments[0].text, node.arguments[1].children) }; return nil } }
    private var count: Int { data.map { $0.cells.count }.max() ?? 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) { ForEach(Array(data.enumerated()), id: \.offset) { _, column in Text(column.label).font(Theme.label).frame(maxWidth: .infinity, alignment: .leading) } }.padding(.vertical, 12)
            Rectangle().fill(Theme.ink).frame(height: 1)
            ForEach(0..<min(100,count), id: \.self) { row in
                HStack(alignment: .top, spacing: 16) { ForEach(Array(data.enumerated()), id: \.offset) { _, column in Text(row < column.cells.count ? column.cells[row].text : "").font(Theme.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.padding(.vertical, 12)
                Rectangle().fill(Theme.rule).frame(height: 1)
            }
            if count > 100 { Text(L10n.format("显示前100行，共{0}行", "\(count)")).font(Theme.label).foregroundStyle(Theme.secondary) }
        }
    }
}

private struct OpenUIControlStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var primary: Bool
    var focused: Bool
    var hovered: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(Theme.body.weight(primary ? .medium : .regular)).foregroundStyle(primary ? Theme.paper : Theme.ink).padding(.horizontal, 14).frame(minHeight: 48).background(primary ? Theme.ink.opacity(configuration.isPressed ? 0.85 : 1) : Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : primary ? Theme.clear : Theme.rule, lineWidth: focused ? 1.5 : 1)).shadow(color: Theme.shadow.opacity(hovered ? 0.10 : 0.06), radius: 2, x: 2, y: 2).opacity(enabled ? 1 : 0.5) }
}

private struct OpenUIActionButton: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var label: String
    var primary: Bool
    var action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false
    var body: some View { Button(label, action: action).buttonStyle(OpenUIControlStyle(primary: primary, focused: focused, hovered: hovered)).focused($focused).onHover { hovered = $0 } }
}
private struct OpenUITextArea: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Binding var text: String
    var name: String
    @FocusState private var focused: Bool
    var body: some View { TextEditor(text: $text).font(Theme.body).scrollContentBackground(.hidden).padding(12).frame(height: 140).background(Theme.sheet).focused($focused).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge)).accessibilityLabel(name) }
}

private struct OpenUIRecordValue: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var value: String
    var body: some View {
        Text(value.isEmpty ? L10n.t("未填写") : value).font(Theme.body).foregroundStyle(Theme.ink)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
