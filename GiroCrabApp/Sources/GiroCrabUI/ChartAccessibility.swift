import SwiftUI

/// VoiceOver / Audio Graph description of a bar chart with named categories on the x axis and one
/// or more value series (euros) on the y axis (#571). Values are read with the app's money format.
struct BarChartDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        let values: [Double]
    }

    let title: String
    var summary: String?
    let categoryTitle: String
    let categories: [String]
    let valueTitle: String
    let series: [Series]

    func makeChartDescriptor() -> AXChartDescriptor {
        let all = series.flatMap(\.values)
        let lo = min(all.min() ?? 0, 0)
        let hi = max(all.max() ?? 1, lo + 1)
        let x = AXCategoricalDataAxisDescriptor(title: categoryTitle, categoryOrder: categories)
        let y = AXNumericDataAxisDescriptor(title: valueTitle, range: lo...hi, gridlinePositions: []) {
            Money.format(Int64(($0 * 100).rounded()))
        }
        let data = series.map { s in
            AXDataSeriesDescriptor(
                name: s.name, isContinuous: false,
                dataPoints: zip(categories, s.values).map { AXDataPoint(x: $0.0, y: $0.1) }
            )
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: data)
    }
}
