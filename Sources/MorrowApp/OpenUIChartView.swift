import SwiftUI
import Charts
import MorrowCore

struct OpenUIChartView: View {
    let kind: String
    let data: OpenUIChartData
    @State private var showData = false
    @State private var selected: String?
    private let palette: [Color] = [Theme.accent2, .teal, .indigo, .orange, .brown, .mint]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(data.title).font(Theme.heading); Spacer(); Button(showData ? L10n.t("图表") : L10n.t("数据表")) { showData.toggle() }.buttonStyle(.link).font(Theme.label) }
            if !data.description.isEmpty { Text(data.description).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            if showData {
                ForEach(data.points) { point in HStack { Text(point.label).lineLimit(2); Spacer(); Text(point.value, format: .number.precision(.fractionLength(0...2))).monospacedDigit() }.font(Theme.body).padding(.vertical, 5).textSelection(.enabled) }
            } else if kind == "PieChart" {
                if data.points.reduce(0, { $0 + $1.value }) == 0 { Text(L10n.t("暂无数据")).foregroundStyle(Theme.muted) }
                else { Chart(data.points) { point in SectorMark(angle: .value("数值", point.value), innerRadius: .ratio(0.6)).foregroundStyle(by: .value("类别", point.label)) }.chartForegroundStyleScale(range: palette).frame(height: 230).chartLegend(position: .bottom) }
            } else if kind == "LineChart" {
                Chart(data.points) { point in LineMark(x: .value("时间", point.label), y: .value("数值", point.value)).foregroundStyle(by: .value("系列", point.series)); PointMark(x: .value("时间", point.label), y: .value("数值", point.value)).foregroundStyle(by: .value("系列", point.series)) }
                    .chartForegroundStyleScale(range: palette).chartXSelection(value: $selected).chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }.frame(height: 230)
            } else {
                Chart(data.points) { point in BarMark(x: .value("数值", point.value), y: .value("类别", point.label)).foregroundStyle(Theme.accent2).cornerRadius(3) }
                    .frame(height: CGFloat(min(400, max(180, data.points.count * 30))))
            }
            if let selected, let point = data.points.first(where: { $0.label == selected }) { Text(point.label + " · " + point.value.formatted()).font(Theme.label).foregroundStyle(Theme.secondary) }
        }.padding(16).background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.rule)).accessibilityIdentifier("openui.chart")
    }
}
struct OpenUIStepsView: View {
    let title: String
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.heading)
            ForEach(Array(items.prefix(20).enumerated()), id: \.offset) { index, item in HStack(alignment: .top, spacing: 12) { Text("\(index + 1)").font(Theme.label).frame(width: 24, height: 24).background(Theme.sidebar, in: Circle()); Text(item).font(Theme.body).fixedSize(horizontal: false, vertical: true) } }
        }.accessibilityIdentifier("openui.steps")
    }
}
