public struct Module: Codable {
    public let name: String
    public internal (set) var kind: Kind
    public var path: String?
    public var dependencies: [String]?

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
        self.path = nil
        self.dependencies = nil
    }

    public var isPublic: Bool {
        switch self.kind {
        case .library(let settings):
            return settings.isPublic
        case .executable:
            return false // TBD
        case .test:
            return false // TBD
        case .system:
            return false // TBD
        case .binary(let settings):
            return settings.isPublic
        case .plugin:
            return true // TBD
        }
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
        public var isPublic: Bool = false
        public var linkage: Linkage = .auto // TBD if needed, or we want to change the model

        public init() {}

        public enum Linkage: Codable {
            case auto
            case dynamic
            case `static`
        }
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
        public var location: String
        public var checksum: String?
        public var isPublic: Bool = false

        public init(path: String) {
            self.location = path
            self.checksum = nil
        }

        public init(url: String, checksum: String) {
            self.location = url
            self.checksum = checksum
        }
    }

    public struct PluginSettings: Codable {
        public var capability: Capability

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
