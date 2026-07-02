/// Vim modal states. The engine itself lands in M3; the mode enum exists from
/// the start so the app shell can show a mode indicator.
public enum VimMode: Equatable, Sendable {
    case insert
    case normal
    case visual(line: Bool)
    case operatorPending

    public var label: String {
        switch self {
        case .insert: return "INSERT"
        case .normal: return "NORMAL"
        case .visual(line: false): return "VISUAL"
        case .visual(line: true): return "V-LINE"
        case .operatorPending: return "O-PEND"
        }
    }
}
