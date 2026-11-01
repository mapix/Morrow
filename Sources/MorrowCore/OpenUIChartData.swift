import Foundation

public struct OpenUIChartPoint: Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let value: Double
    public let series: String
}
public struct OpenUIChartData: Sendable {
    public let title: String
    public let description: String
    public let points: [OpenUIChartPoint]
    public init(node: OpenUINode) throws {
        guard ["BarChart", "LineChart", "PieChart"].contains(node.name), node.arguments.count >= 2 else { throw OpenUIError.message("图表参数不完整。") }
        title = String(node.arguments[0].text.prefix(240))
        description = node.arguments.count > 2 ? String(node.arguments[2].text.prefix(1000)) : ""
        let data = node.arguments[1].children
        guard !data.isEmpty, data.count <= 200 else { throw OpenUIError.message("图表需要1到200项实际数据。") }
        points = try data.enumerated().map { index, item in
            let values = try item.json().object
            guard let label = values["label"]?.text, !label.isEmpty, label.count <= 120,
                  case .number(let value) = values["value"], value.isFinite, abs(value) <= 1e15,
                  node.name != "PieChart" || value >= 0 else { throw OpenUIError.message("图表标签或数值无效。") }
            return OpenUIChartPoint(id: index, label: label, value: value, series: String((values["series"]?.text ?? "数值").prefix(120)))
        }
    }
}
public extension OpenUIValue {
    var needsUserInput: Bool {
        switch self {
        case .node(let node): return ["Input", "TextArea", "Choice"].contains(node.name) || node.arguments.contains(where: \.needsUserInput)
        case .action(let action): return ["ToAssistant", "SaveResponder", "ConfigureResponder"].contains(action.name)
        case .actions(let actions): return actions.contains { ["ToAssistant", "SaveResponder", "ConfigureResponder"].contains($0.name) }
        case .array(let children): return children.contains(where: \.needsUserInput)
        default: return false
        }
    }
    func validatePresentation(depth: Int = 0) throws {
        guard depth < 40 else { throw OpenUIError.message("结构化内容层数过多。") }
        switch self {
        case .node(let node):
            if ["BarChart", "LineChart", "PieChart"].contains(node.name) { _ = try OpenUIChartData(node: node) }
            for child in node.arguments { try child.validatePresentation(depth: depth + 1) }
        case .array(let children): for child in children { try child.validatePresentation(depth: depth + 1) }
        default: break
        }
    }
}
