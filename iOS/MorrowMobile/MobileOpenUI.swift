import SwiftUI
import MorrowCore

/// Shared OpenUI Lang, rendered as native controls. Only explicit button taps
/// dispatch host actions; the renderer never runs generated code or URLs.
struct MobileOpenUI: View {
    @EnvironmentObject var model: MobileModel
    let interaction: OpenUIInteraction
    @State private var values: [String: OpenUIJSON]
    @State private var failure: String?
    @State private var busy = false
    init(interaction: OpenUIInteraction) { self.interaction = interaction; _values = State(initialValue: interaction.values) }
    var current: OpenUIInteraction { model.interactions.first { $0.id == interaction.id } ?? interaction }
    var root: OpenUIValue? { try? OpenUILang.parse(current.source).root(state: values) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let root { render(root, form: nil, insideCard: false) }
            else { Text(MobileL10n.text("结构化交互无法显示，请用聊天继续。")).font(.caption) }
            if let receipt = current.receipt { Text(receipt).font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.disabled(busy || current.completedAt != nil)
    }
    func render(_ value: OpenUIValue, form: String?, insideCard: Bool) -> AnyView {
        guard case .node(let node) = value else { return AnyView(Text(value.text)) }
        func arg(_ index: Int) -> OpenUIValue { node.arguments.indices.contains(index) ? node.arguments[index] : .json(.null) }
        func children(_ values: [OpenUIValue], form: String?, insideCard: Bool) -> AnyView { AnyView(VStack(alignment: .leading, spacing: 14) { ForEach(Array(values.enumerated()), id: \.offset) { _, child in render(child, form: form, insideCard: insideCard) } }) }
        switch node.name {
        case "Stack": return children(arg(0).children, form: form, insideCard: insideCard)
        case "Card": let body = children(arg(0).children, form: form, insideCard: true); return insideCard ? body : AnyView(body.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 14)))
        case "Form": return children(arg(1).children, form: arg(0).text, insideCard: insideCard)
        case "CardHeader": return AnyView(VStack(alignment: .leading, spacing: 6) { Text(arg(0).text).font(.headline); Text(arg(1).text).font(.subheadline).foregroundStyle(.secondary) })
        case "Text", "TextContent", "Markdown": return AnyView(Text(arg(0).text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true))
        case "FormControl": return AnyView(VStack(alignment: .leading, spacing: 6) { Text(arg(0).text).font(.caption).foregroundStyle(.secondary); render(arg(1), form: form, insideCard: insideCard) })
        case "Input", "TextArea": return AnyView(TextField(arg(1).text, text: binding(name: arg(0).text, fallback: arg(2), form: form), axis: node.name == "TextArea" ? .vertical : .horizontal).lineLimit(node.name == "TextArea" ? 3...8 : 1...1).textInputAutocapitalization(.never).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(arg(0).text))
        case "Choice":
            let options = arg(2).children.map { value -> (String, String) in let object = (try? value.json().object) ?? [:]; return object.isEmpty ? (value.text, value.text) : (object["label"]?.text ?? "", object["value"]?.text ?? "") }
            return AnyView(Picker(arg(1).text, selection: binding(name: arg(0).text, fallback: arg(3), form: form)) { ForEach(options, id: \.1) { option in Text(option.0).tag(option.1) } })
        case "Buttons": return children(arg(0).children, form: form, insideCard: insideCard)
        case "Button": return AnyView(Button(arg(0).text) { submit(arg(1).actions, form: form) }.buttonStyle(.bordered).disabled(arg(1).actions.isEmpty))
        case "Citation": return AnyView(Button(arg(1).text) { submit([.init(name: "OpenMailSource", arguments: [arg(0)])], form: form) }.font(.caption))
        case "Table":
            return AnyView(ScrollView(.horizontal) { HStack(alignment: .top, spacing: 16) { ForEach(Array(arg(0).children.enumerated()), id: \.offset) { _, value in if case .node(let column) = value, column.name == "Col", column.arguments.count == 2 { VStack(alignment: .leading, spacing: 10) { Text(column.arguments[0].text).font(.caption).fontWeight(.semibold); ForEach(Array(column.arguments[1].children.prefix(100).enumerated()), id: \.offset) { _, cell in Text(cell.text).font(.caption) } }.frame(minWidth: 100, alignment: .leading) } } } })
        default: return AnyView(Text("Unsupported native component: " + node.name).font(.caption))
        }
    }
    func binding(name: String, fallback: OpenUIValue, form: String?) -> Binding<String> {
        let key = (form ?? "page") + ":" + name
        return Binding(get: { values[key]?.text ?? fallback.text }, set: { text in
            values[key] = .string(text); if case .binding(let name, _) = fallback { values[name] = .string(text) }
            let snapshot = values
            Task { do { try await model.editInteraction(current.id, values: snapshot) } catch { failure = error.localizedDescription } }
        })
    }
    func fields(_ value: OpenUIValue, form: String?, target: String?) throws -> [String: OpenUIJSON] {
        guard case .node(let node) = value else { var all: [String: OpenUIJSON] = [:]; for child in value.children { all.merge(try fields(child, form: form, target: target)) { _, latest in latest } }; return all }
        let owner = node.name == "Form" ? node.arguments.first?.text : form
        var result: [String: OpenUIJSON] = [:]
        if ["Input", "TextArea", "Choice"].contains(node.name), node.arguments.count >= 3, target == nil || owner == target {
            let name = node.arguments[0].text, index = node.name == "Choice" ? 3 : 2
            let fallback = node.arguments.indices.contains(index) ? node.arguments[index].text : ""
            let text = values[(owner ?? "page") + ":" + name]?.text ?? fallback
            if node.name != "Choice", node.arguments.count >= 4 {
                let rules = (try? node.arguments[3].json().object) ?? [:]
                if rules["required"]?.truth == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MailError.message("请填写 " + name) }
                if rules["email"]?.truth == true && !text.isEmpty && !(name == "sender" ? MailResponder.validSender(text) : MailAddress.isValid(text)) { throw MailError.message("邮箱格式无效: " + name) }
            }
            result[name] = .string(text)
        }
        for child in node.arguments { result.merge(try fields(child, form: owner, target: target)) { _, latest in latest } }
        return result
    }
    func submit(_ actions: [OpenUIAction], form: String?) {
        guard let root, current.completedAt == nil, !busy else { return }
        do {
            let collected = try fields(root, form: nil, target: form); busy = true
            Task { do { try await model.handleInteraction(current.id, actions: actions, fields: collected); busy = false } catch { failure = error.localizedDescription; busy = false } }
        } catch { failure = error.localizedDescription }
    }
}

extension MobileModel {
    func editInteraction(_ id: String, values: [String: OpenUIJSON]) async throws {
        guard let index = interactions.firstIndex(where: { $0.id == id && $0.completedAt == nil }) else { return }
        interactions[index].values = values; interactions[index].stateRevision += 1
        let page = interactions[index]; try await store.updateOpenUIState(values, id: id, revision: page.stateRevision)
    }
    func handleInteraction(_ id: String, actions: [OpenUIAction], fields: [String: OpenUIJSON]) async throws {
        guard var page = interactions.first(where: { $0.id == id && $0.completedAt == nil }), !busy else { throw MailError.message("当前交互忙或已结束。") }
        for action in actions {
            switch action.name {
            case "SaveResponder":
                var rule = MailResponder(); rule.title = fields["title"]?.text ?? ""; rule.accountID = fields["accountID"]?.text ?? ""; rule.sender = fields["sender"]?.text ?? ""; rule.subjectContains = fields["subject"]?.text ?? ""; rule.bodyContains = fields["body"]?.text ?? ""; rule.response = fields["response"]?.text ?? ""; rule.useAI = fields["contentMode"]?.text == "ai"
                try await saveResponder(rule); page.receipt = "响应器已保存；手机在前台同步时生成草稿，不自动发送。"; page.completedAt = Date()
            case "ToAssistant":
                guard let sessionID = page.sessionID else { throw MailError.message("交互的来源对话不存在。") }
                let submitted = action.arguments.first?.text ?? ""; let encoded = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
                await appendVoice(submitted + "\n用户提交的结构化选择:\n" + encoded, sessionID: sessionID); selectSession(sessionID)
                page.completedAt = Date(); page.receipt = "选择已保存到来源对话。"
            case "OpenDraft": guard let value = action.arguments.first?.text, let draft = drafts.first(where: { $0.id == value }) else { throw MailError.message("草稿不存在。") }; compose = draft
            case "OpenMailSource": guard let value = action.arguments.first?.text, let mail = mails.first(where: { $0.id == value }), page.runID.flatMap({ id in runs.first(where: { $0.id == id })?.sourceMailIDs.contains(value) }) ?? false else { throw MailError.message("引用邮件不属于本次交互。") }; try await openNativeMail(mail)
            default: throw MailError.message("手机未提供 OpenUI 动作: " + action.name)
            }
        }
        try await store.save(page, kind: "openui-interaction", id: page.id); interactions = interactions.map { $0.id == id ? page : $0 }
        if actions.contains(where: { $0.name == "ToAssistant" }) { await submit() }
    }
}
