import Foundation

/// Keeps partial repairs out of persisted settings and runtime controls.
/// Invalid legacy configurations can be repaired over several edits without losing progress.
struct RuleEditingDraft<Rule> {
    private(set) var rules: [Rule]?
    private(set) var message: String?

    mutating func update(
        _ candidate: [Rule],
        validate: ([Rule]) throws -> Void,
        save: ([Rule]) throws -> Void
    ) {
        rules = candidate
        do {
            try validate(candidate)
            try save(candidate)
            discard()
        } catch {
            message = error.localizedDescription
        }
    }

    mutating func discard() {
        rules = nil
        message = nil
    }
}
