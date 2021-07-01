// type-erasor

public struct Module: Codable {
    public let name: String
    public internal (set) var kind: Kind
    public var path: String?

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
        self.path = nil
    }
}

extension Module {
    public enum Kind: Codable {
        case library(LibrarySettings)
        case executable(ExecutableSettings)
        case test(TestSettings)
        case system(SystemSettings)
        case binary(BinarySettings)
        case plugin(PluginSettings)
    }

    public struct LibrarySettings: SourceModuleSettings, Codable {
        public var sources: [String]?
        public var resources: [String]?
        public var exclude: [String]?
        public var cSettings: [String]?
        public var cxxSettings: [String]?
        public var swiftSettings: [String]?
        public var linkerSettings: [String]?

        public init() {}
    }

    public struct ExecutableSettings: SourceModuleSettings, Codable {
        public var sources: [String]?
        public var resources: [String]?
        public var exclude: [String]?
        public var cSettings: [String]?
        public var cxxSettings: [String]?
        public var swiftSettings: [String]?
        public var linkerSettings: [String]?

        public init() {}
    }

    public struct TestSettings: SourceModuleSettings, Codable {
        public var sources: [String]?
        public var resources: [String]?
        public var exclude: [String]?
        public var cSettings: [String]?
        public var cxxSettings: [String]?
        public var swiftSettings: [String]?
        public var linkerSettings: [String]?

        public init() {}
    }

    public struct SystemSettings: Codable {
        var providers: [String]

        public init() {
            self.providers = []
        }
    }

    public struct BinarySettings: Codable {
        var checksum: String

        public init(checksum: String) {
            self.checksum = checksum
        }
    }

    public struct PluginSettings: Codable {
        var capability: Capability

        init(capability: Capability) {
            self.capability = capability
        }

        public enum Capability: Codable {
            case buildTool
        }
    }
}

public protocol SourceModuleSettings {
    var sources: [String]? { get set }
    var resources: [String]? { get set }
    var exclude: [String]? { get set }
    var cSettings: [String]? { get set }
    var cxxSettings: [String]? { get set }
    var swiftSettings: [String]? { get set }
    var linkerSettings: [String]? { get set }
}


