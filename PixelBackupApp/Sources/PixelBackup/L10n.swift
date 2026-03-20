import Foundation

/// Thin wrapper around NSLocalizedString that always uses the module bundle.
/// All user-visible strings that are NOT SwiftUI Text literals (e.g. computed
/// properties, notification content) should go through this helper so that a
/// translator can add a new *.lproj directory and have everything work.
///
/// Usage:
///   L10n("backup.state.copying")
///   L10n("backup.state.failed", message)          // with one %@ arg
///   L10n("notification.backup.body.success", 42, 3.5)  // with multiple args
func L10n(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .module, comment: "")
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args)
}
