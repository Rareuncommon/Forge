/// What a front end supplies to the shared model: native dialogs.
@MainActor
package protocol PlatformServices: AnyObject {
    /// A yes/no question; true when the user chose `confirm`.
    func confirm(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool
    /// A path to save to (nil: cancelled). `name` is the suggested file name.
    func chooseSavePath(suggestedName name: String) -> String?
    /// A document to open (nil: cancelled).
    func chooseOpenPath() -> String?
}

/// No UI (tests, headless): confirms everything, never picks a file.
@MainActor
package final class HeadlessPlatform: PlatformServices {
    package init() {}
    package func confirm(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool { true }
    package func chooseSavePath(suggestedName name: String) -> String? { nil }
    package func chooseOpenPath() -> String? { nil }
}
