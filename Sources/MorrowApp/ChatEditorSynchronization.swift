import Foundation

enum ChatEditorSynchronization {
    static func isPendingModelEcho(model: String, native: String, publishedNative: String?, previousModel: String) -> Bool {
        publishedNative == native && model == previousModel && model != native
    }
    static func replacement(model: String, native: String, hasMarkedText: Bool) -> String? {
        // Marked text belongs to the input method. The model may still contain
        // the previous committed string while candidates are being composed.
        guard !hasMarkedText, model != native else { return nil }
        return model
    }
    static func selection(_ range: NSRange, replacing old: String, with new: String) -> NSRange {
        let before = Array(old.utf16), after = Array(new.utf16)
        let location = min(max(0, range.location == NSNotFound ? before.count : range.location), before.count)
        let length = min(max(0, range.length), before.count - location)
        if length == 0 && location == before.count { return NSRange(location: after.count, length: 0) }
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count - prefix, after.count - prefix), before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        func position(_ value: Int) -> Int {
            if value <= prefix { return value }
            if value >= before.count - suffix { return after.count - suffix + value - (before.count - suffix) }
            return after.count - suffix
        }
        let start = min(max(0, position(location)), after.count)
        let end = min(max(start, position(location + length)), after.count)
        return NSRange(location: start, length: end - start)
    }
}
