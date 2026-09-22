import Foundation

/// How the app is told what to do at launch, without anybody touching it.
///
/// The probes have always read environment variables, which works when the
/// binary inside the bundle is run directly. That route stopped making a
/// window at all after LaunchServices was rebuilt on this machine, and
/// `open`, which starts a bundle the way the Finder does, has no way to pass
/// an environment — only arguments. So every setting answers to both: the
/// variable `PAPERTIME_TRACE`, or the argument `--papertime-trace=1`.
///
///     open -n -a "Paper Time" --args --papertime-trace=1 --papertime-open-title=EWC
enum Boot {
    /// The value given for a setting, from the environment or the command
    /// line. Nil when it was not given at all.
    static func setting(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name] { return value }
        let flag = "--" + name.lowercased().replacingOccurrences(of: "_", with: "-") + "="
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix(flag) {
            return String(argument.dropFirst(flag.count))
        }
        // A bare flag stands for itself, for the settings that are only ever
        // on or off.
        let bare = "--" + name.lowercased().replacingOccurrences(of: "_", with: "-")
        return ProcessInfo.processInfo.arguments.contains(bare) ? "" : nil
    }

    static func isSet(_ name: String) -> Bool { setting(name) != nil }
}

extension String {
    /// The rest of the string after a prefix, or nil when it does not start
    /// with one. For settings that carry a kind and a value in one word.
    func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
