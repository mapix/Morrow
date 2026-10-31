import Foundation

struct RichTextExportRevision {
    private(set) var current = 0
    private var exported: Int?
    var needsExport: Bool { exported != current }
    mutating func edited() { current += 1 }
    mutating func imported(hasHTML: Bool) { current += 1; exported = hasHTML ? current : nil }
    mutating func acknowledge(_ revision: Int) { if revision == current { exported = revision } }
}
