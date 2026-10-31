import Foundation

public enum OpenUIJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([OpenUIJSON]), object([String: OpenUIJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([OpenUIJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: OpenUIJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
    public var text: String { switch self { case .string(let v): return v; case .number(let v): return v == v.rounded() && abs(v) < Double(Int.max) ? String(Int(v)) : String(v); case .bool(let v): return v ? "true" : "false"; case .null: return ""; default: return String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" } }
    public var object: [String: OpenUIJSON] { if case .object(let v) = self { return v }; return [:] }
    public var truth: Bool { switch self { case .null: return false; case .bool(let b): return b; case .number(let n): return n != 0; case .string(let s): return !s.isEmpty; default: return true } }
}

public indirect enum OpenUIExpression: Sendable {
    case literal(OpenUIJSON), reference(String), array([OpenUIExpression]), object([(String, OpenUIExpression)]), call(String, [OpenUIExpression]), unary(String, OpenUIExpression), binary(String, OpenUIExpression, OpenUIExpression), conditional(OpenUIExpression, OpenUIExpression, OpenUIExpression), field(OpenUIExpression, OpenUIExpression), member(OpenUIExpression, String)
}
public struct OpenUIProgram: Sendable {
    public var definitions: [String: OpenUIExpression]
    public func root(state: [String: OpenUIJSON] = [:]) throws -> OpenUIValue {
        guard definitions["root"] != nil else { throw OpenUIError.message("OpenUI 输出缺少 root。") }
        return try evaluate(.reference("root"), state: state)
    }
    public func evaluate(_ expression: OpenUIExpression, state: [String: OpenUIJSON] = [:], visiting: Set<String> = [], depth: Int = 0) throws -> OpenUIValue {
        guard depth < 80 else { throw OpenUIError.message("OpenUI 引用层数过多。") }
        func run(_ e: OpenUIExpression) throws -> OpenUIValue { try evaluate(e, state: state, visiting: visiting, depth: depth + 1) }
        switch expression {
        case .literal(let value): return .json(value)
        case .reference(let name):
            if name.hasPrefix("$"), let value = state[name] { return .binding(name, value) }
            guard !visiting.contains(name), let value = definitions[name] else { throw OpenUIError.message("OpenUI 引用不存在或形成循环：" + name) }
            let evaluated = try evaluate(value, state: state, visiting: visiting.union([name]), depth: depth + 1)
            return name.hasPrefix("$") ? .binding(name, try evaluated.json()) : evaluated
        case .array(let values): return .array(try values.map(run))
        case .object(let values): var result: [String: OpenUIValue] = [:]; for (key, value) in values { result[key] = try run(value) }; return .object(result)
        case .call(let name, let arguments):
            let values = try arguments.map(run)
            if name == "@Action" { return .actions(values.flatMap { $0.actions }) }
            if name.hasPrefix("@") {
                let action = String(name.dropFirst())
                guard OpenUINativeLibrary.actions[action] != nil || action == "ToAssistant" else { throw OpenUIError.unsupported("函数 " + name) }
                return .action(OpenUIAction(name: action, arguments: values))
            }
            guard OpenUINativeLibrary.components[name] != nil else { throw OpenUIError.unsupported("组件 " + name) }
            guard values.count <= (OpenUINativeLibrary.components[name]?.count ?? 0) else { throw OpenUIError.message("OpenUI 组件参数与当前库不一致：" + name) }
            return .node(OpenUINode(name: name, arguments: values))
        case .unary(let op, let e):
            let value = try run(e).json()
            if op == "!" { return .json(.bool(!value.truth)) }
            guard case .number(let n) = value else { throw OpenUIError.message("OpenUI 数值运算类型不符。") }; return .json(.number(-n))
        case .conditional(let condition, let a, let b): return try run(run(condition).json().truth ? a : b)
        case .binary(let op, let a, let b):
            let left = try run(a).json()
            if op == "&&" && !left.truth { return .json(left) }; if op == "||" && left.truth { return .json(left) }
            let right = try run(b).json()
            if op == "&&" || op == "||" { return .json(right) }
            if op == "==" || op == "!=" { return .json(.bool(op == "==" ? left == right : left != right)) }
            if op == "+", case .string = left { return .json(.string(left.text + right.text)) }
            if op == "+", case .string = right { return .json(.string(left.text + right.text)) }
            guard case .number(let x) = left, case .number(let y) = right else { throw OpenUIError.message("OpenUI 运算类型不符。") }
            switch op { case "+": return .json(.number(x+y)); case "-": return .json(.number(x-y)); case "*": return .json(.number(x*y)); case "/", "%": guard y != 0 else { throw OpenUIError.message("OpenUI 不能除以零。") }; return .json(.number(op == "/" ? x/y : x.truncatingRemainder(dividingBy: y))); case ">": return .json(.bool(x>y)); case "<": return .json(.bool(x<y)); case ">=": return .json(.bool(x>=y)); case "<=": return .json(.bool(x<=y)); default: throw OpenUIError.unsupported(op) }
        case .field(let base, let key):
            let value = try run(base); let index = try run(key).json()
            if case .object(let object) = value { return object[index.text] ?? .json(.null) }
            let json = try value.json()
            if case .object(let object) = json { return .json(object[index.text] ?? .null) }
            if case .array(let array) = json, case .number(let n) = index, n >= 0, n < Double(array.count), n == n.rounded() { return .json(array[Int(n)]) }
            return .json(.null)
        case .member(let base, let key):
            let json = try run(base).json()
            func field(_ item: OpenUIJSON) -> OpenUIJSON { if case .object(let object) = item { return object[key] ?? .null }; if case .array(let array) = item, let index = Int(key), index >= 0, index < array.count { return array[index] }; return .null }
            if case .array(let array) = json { return .json(.array(array.map(field))) }; return .json(field(json))
        }
    }
}
public struct OpenUINode: Sendable { public var name: String; public var arguments: [OpenUIValue] }
public struct OpenUIAction: Sendable { public var name: String; public var arguments: [OpenUIValue]; public init(name: String, arguments: [OpenUIValue]) { self.name = name; self.arguments = arguments } }
public indirect enum OpenUIValue: Sendable {
    case json(OpenUIJSON), binding(String, OpenUIJSON), array([OpenUIValue]), object([String: OpenUIValue]), node(OpenUINode), action(OpenUIAction), actions([OpenUIAction])
    public func json() throws -> OpenUIJSON { switch self { case .json(let v), .binding(_, let v): return v; case .array(let v): return .array(try v.map { try $0.json() }); case .object(let v): return .object(try v.mapValues { try $0.json() }); default: throw OpenUIError.message("OpenUI 组件不能作为数据发送。") } }
    public var text: String { (try? json().text) ?? "" }
    public var children: [OpenUIValue] { switch self { case .array(let v): return v; case .json(.array(let v)), .binding(_, .array(let v)): return v.map { .json($0) }; default: return [] } }
    public var actions: [OpenUIAction] { switch self { case .action(let v): return [v]; case .actions(let v): return v; case .array(let v): return v.flatMap(\.actions); default: return [] } }
}
public enum OpenUIError: LocalizedError { case message(String), unsupported(String); public var errorDescription: String? { switch self { case .message(let m): return m; case .unsupported(let m): return "Morrow 原生 OpenUI profile 暂不支持" + m + "。" } } }

public enum OpenUILang {
    public static func parse(_ source: String) throws -> OpenUIProgram { try Parser(source).program() }
    private enum Token: Equatable { case name(String), string(String), number(Double), symbol(String), newline, end }
    private final class Parser {
        var tokens: [Token] = []; var offset = 0; var nesting = 0; var recursion = 0
        init(_ source: String) throws {
            guard source.utf8.count <= 65536 else { throw OpenUIError.message("OpenUI 输出超过本机交互长度限制。") }
            var lines: [String] = []; var fenced = false; var foundFence = false
            for line in source.components(separatedBy: .newlines) { if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); foundFence = true } else if fenced { lines.append(line) } }
            let text = foundFence ? lines.joined(separator: "\n") : source
            let chars = Array(text); var i = 0
            func letter(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
            while i < chars.count {
                let c = chars[i]
                if c == "\n" { tokens.append(.newline); i += 1; continue }
                if c.isWhitespace { i += 1; continue }
                if c == "/", i+1 < chars.count, chars[i+1] == "/" { while i < chars.count && chars[i] != "\n" { i += 1 }; continue }
                if c == "#" { while i < chars.count && chars[i] != "\n" { i += 1 }; continue }
                if c == "/", i+1 < chars.count, chars[i+1] == "*" { i += 2; while i+1 < chars.count && !(chars[i] == "*" && chars[i+1] == "/") { i += 1 }; i = min(chars.count, i+2); continue }
                if c == "\"" || c == "'" {
                    let quote = c; i += 1; var raw = ""; var closed = false
                    while i < chars.count {
                        let next = chars[i]; i += 1
                        if next == quote { closed = true; break }
                        if next == "\\", i < chars.count {
                            let escape = chars[i]; i += 1
                            if quote == "\"" { raw.append("\\"); raw.append(escape) }
                            else { switch escape { case "n": raw.append("\n"); case "r": raw.append("\r"); case "t": raw.append("\t"); default: raw.append(escape) } }
                        } else if quote == "\"", next == "\n" { raw += "\\n" }
                        else if quote == "\"", next == "\r" { raw += "\\r" }
                        else if quote == "\"", next == "\t" { raw += "\\t" }
                        else { raw.append(next) }
                    }
                    guard closed else { throw OpenUIError.message("OpenUI 字符串未结束。") }
                    if quote == "\"" { let full = "\"" + raw + "\""; guard let decoded = try? JSONDecoder().decode(String.self, from: Data(full.utf8)) else { throw OpenUIError.message("OpenUI 字符串转义无效。") }; tokens.append(.string(decoded)) }
                    else { tokens.append(.string(raw)) }; continue
                }
                if letter(c) || c == "$" || c == "@" {
                    var name = String(c); i += 1; while i < chars.count && (letter(chars[i]) || chars[i].isASCII && chars[i].isNumber) { name.append(chars[i]); i += 1 }; tokens.append(.name(name)); continue
                }
                if c.isASCII && c.isNumber {
                    var number = ""; var exponent = false
                    while i < chars.count {
                        let n = chars[i]
                        if n.isASCII && n.isNumber || n == "." { number.append(n); i += 1 }
                        else if (n == "e" || n == "E") && !exponent { exponent = true; number.append(n); i += 1; if i < chars.count && (chars[i] == "+" || chars[i] == "-") { number.append(chars[i]); i += 1 } }
                        else { break }
                    }
                    guard let value = Double(number), value.isFinite else { throw OpenUIError.message("OpenUI 数值无效。") }; tokens.append(.number(value)); continue
                }
                let two = i+1 < chars.count ? String([c, chars[i+1]]) : ""
                if ["||", "&&", "==", "!=", ">=", "<="].contains(two) { tokens.append(.symbol(two)); i += 2 }
                else if "=?:+-*/%!><.,()[]{}".contains(c) { tokens.append(.symbol(String(c))); i += 1 }
                else { i += 1 }
                guard tokens.count <= 10000 else { throw OpenUIError.message("OpenUI 输出过于复杂。") }
            }
            guard tokens.count <= 10000 else { throw OpenUIError.message("OpenUI 输出过于复杂。") }; tokens.append(.end)
        }
        var token: Token { tokens[min(offset, tokens.count-1)] }
        func take(_ symbol: String) -> Bool { if token == .symbol(symbol) { offset += 1; return true }; return false }
        func require(_ symbol: String) throws { guard take(symbol) else { throw OpenUIError.message("OpenUI 语法缺少 " + symbol) } }
        func newlines() { while token == .newline { offset += 1 } }
        func program() throws -> OpenUIProgram {
            var result: [String: OpenUIExpression] = [:]; newlines()
            while token != .end {
                guard case .name(let name) = token, !name.hasPrefix("@") else { throw OpenUIError.message("OpenUI 需要命名语句。") }; offset += 1; try require("="); result[name] = try expression()
                guard token == .newline || token == .end else { throw OpenUIError.message("OpenUI 语句之间需要换行。") }; newlines()
            }
            return OpenUIProgram(definitions: result)
        }
        func expression() throws -> OpenUIExpression {
            guard recursion < 200 else { throw OpenUIError.message("OpenUI 表达式过深。") }; recursion += 1; defer { recursion -= 1 }
            newlines(); var result = try binary(0)
            if take("?") { let yes = try expression(); newlines(); try require(":"); let no = try expression(); result = .conditional(result, yes, no) }
            return result
        }
        let levels = [["||"], ["&&"], ["==", "!="], [">", "<", ">=", "<="], ["+", "-"], ["*", "/", "%"]]
        func binary(_ level: Int) throws -> OpenUIExpression {
            if level == levels.count { return try unary() }
            var left = try binary(level+1)
            while true {
                if nesting > 0 { newlines() }
                guard case .symbol(let op) = token, levels[level].contains(op) else { break }; offset += 1; newlines(); left = .binary(op, left, try binary(level+1))
            }; return left
        }
        func unary() throws -> OpenUIExpression {
            guard recursion < 200 else { throw OpenUIError.message("OpenUI 表达式过深。") }; recursion += 1; defer { recursion -= 1 }
            if take("!") { newlines(); return .unary("!", try unary()) }; if take("-") { newlines(); return .unary("-", try unary()) }
            var value = try primary()
            while true {
                if take(".") { let key: String; switch token { case .name(let name): key = name; case .number(let number): key = OpenUIJSON.number(number).text; default: throw OpenUIError.message("OpenUI 字段名称无效。") }; offset += 1; value = .member(value, key) }
                else if take("[") { nesting += 1; let key = try expression(); newlines(); try require("]"); nesting -= 1; value = .field(value, key) }
                else { break }
            }; return value
        }
        func arguments(_ end: String) throws -> [OpenUIExpression] {
            nesting += 1; defer { nesting -= 1 }; var result: [OpenUIExpression] = []; newlines()
            while token != .symbol(end) && token != .end { result.append(try expression()); _ = take(","); newlines(); guard result.count < 1000 else { throw OpenUIError.message("OpenUI 参数过多。") } }
            try require(end); return result
        }
        func primary() throws -> OpenUIExpression {
            newlines()
            switch token {
            case .string(let value): offset += 1; return .literal(.string(value))
            case .number(let value): offset += 1; return .literal(.number(value))
            case .name(let name):
                offset += 1
                if name == "true" || name == "false" { return .literal(.bool(name == "true")) }; if name == "null" { return .literal(.null) }
                if take("(") { return .call(name, try arguments(")")) }; return .reference(name)
            case .symbol("["): offset += 1; return .array(try arguments("]"))
            case .symbol("("): offset += 1; nesting += 1; let e = try expression(); newlines(); try require(")"); nesting -= 1; return e
            case .symbol("{"):
                offset += 1; nesting += 1; defer { nesting -= 1 }; var fields: [(String, OpenUIExpression)] = []; newlines()
                while token != .symbol("}") && token != .end {
                    let key: String
                    switch token { case .name(let n), .string(let n): key = n; case .number(let n): key = OpenUIJSON.number(n).text; default: throw OpenUIError.message("OpenUI 对象字段无效。") }
                    offset += 1; try require(":"); fields.append((key, try expression())); _ = take(","); newlines()
                }; try require("}"); return .object(fields)
            default: throw OpenUIError.message("OpenUI 表达式不完整。")
            }
        }
    }
}

public enum OpenUINativeLibrary {
    public static let id = "morrow-native"
    public static let version = "0.1.0"
    /// Parameter order is part of the OpenUI LibrarySpec, not dictionary sorting.
    public static let components: [String: [String]] = ["Stack": ["children"], "Card": ["children"], "CardHeader": ["title", "subtitle"], "TextContent": ["text", "style"], "Text": ["text"], "Markdown": ["text"], "Table": ["columns"], "Col": ["label", "data"], "Form": ["name", "children"], "FormControl": ["label", "child"], "Input": ["name", "placeholder", "value", "rules"], "TextArea": ["name", "placeholder", "value", "rules"], "Choice": ["name", "label", "options", "value"], "Buttons": ["children", "direction"], "Button": ["label", "action", "variant"], "Citation": ["sourceId", "label"]]
    public static let actions: [String: [String]] = ["OpenMailSource": ["sourceId"], "OpenDraft": ["draftId"], "ConfigureResponder": [], "SaveResponder": []]
    public static var prompt: String {
        "OpenUI Lang 1.0 的 Morrow 原生 profile。只返回完整的 Lang 命名语句，首行 root = ...，不要 HTML、JS、Markdown代码围栏或JSON组件树。可用组件参数顺序如下：\n" + components.sorted { $0.key < $1.key }.map { "\($0.key)(\($0.value.joined(separator: ", ")))" }.joined(separator: "\n") + "\nInput/TextArea 第三个参数是值或 $绑定，第四个是规则对象（required、email、minLength）。Form(name, children)限定字段范围；Choice options为字符串数组或{label,value}对象数组。按钮动作使用 @ToAssistant(message, context?) 或 @SaveResponder()、@ConfigureResponder()、@OpenMailSource(sourceId)、@OpenDraft(draftId)。所有动作只在用户点击时触发，不能声称动作已完成。禁止 Query、Mutation、外部URL。引用可以前向定义。标题与正文用中文。"
    }
}

public struct OpenUIActionEvent: Codable, Sendable {
    public var type: String
    public var humanFriendlyMessage: String
    public var params: [String: OpenUIJSON]
    public var formName: String?
    public var formState: [String: [String: OpenUIFieldState]]?
    public init(type: String, humanFriendlyMessage: String = "", params: [String: OpenUIJSON] = [:], formName: String? = nil, formState: [String: [String: OpenUIFieldState]]? = nil) { self.type = type; self.humanFriendlyMessage = humanFriendlyMessage; self.params = params; self.formName = formName; self.formState = formState }
}
public struct OpenUIFieldState: Codable, Sendable { public var value: OpenUIJSON; public var componentType: String?; public init(value: OpenUIJSON, componentType: String? = "input") { self.value = value; self.componentType = componentType } }
public struct OpenUIInteraction: Codable, Identifiable, Sendable {
    public var sessionID: String?
    public var id = UUID().uuidString
    public var runID: String?
    public var source: String
    public var libraryID = OpenUINativeLibrary.id
    public var libraryVersion = OpenUINativeLibrary.version
    public var langVersion = "1.0"
    public var messageStatus = "completed"
    public var values: [String: OpenUIJSON] = [:]
    public var stateRevision = 0
    public var createdAt = Date()
    public var completedAt: Date?
    public var receipt: String?
    public init(source: String, runID: String? = nil) { self.source = source; self.runID = runID }
}
