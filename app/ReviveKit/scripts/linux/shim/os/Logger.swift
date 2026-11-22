// Linux stand-in for Apple's os.Logger: enough API for ReviveKit to compile; messages are dropped.
public struct OSLogPrivacy: Sendable {
    public static let `public` = OSLogPrivacy()
    public static let `private` = OSLogPrivacy()
}
public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: OSLogPrivacy = .private) {}
    }
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public init() {}
    public func debug(_ m: OSLogMessage) {}
    public func info(_ m: OSLogMessage) {}
    public func notice(_ m: OSLogMessage) {}
    public func warning(_ m: OSLogMessage) {}
    public func error(_ m: OSLogMessage) {}
    public func fault(_ m: OSLogMessage) {}
    public func log(_ m: OSLogMessage) {}
}
