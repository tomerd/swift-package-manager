public protocol PackageModule {
    //associatedtype Settings

    var name: String { get }
    //var kind: Package.Module<Settings>.Kind<Settings> { get }
    var path: String? { get }
}


extension Package {
    public struct Module<Settings>: PackageModule {
        public let name: String
        public internal (set) var kind: Kind<Settings>
        public var path: String?

        public init(name: String, kind: Kind<Settings>, path: String? = nil) {
            self.name = name
            self.kind = kind
            self.path = path
        }
    }
}

extension Package.Module {
    public enum Kind<Settings> {
        case regular(Settings)
        case executable(Settings)
        case test(Settings)
        case system(Settings)
        case binary(Settings)
        case plugin(Settings)

        internal var settings: Settings {
            switch self {
            case .regular(let settings):
                return settings
            case .executable(let settings):
                return settings
            case .test(let settings):
                return settings
            case .system(let settings):
                return settings
            case .binary(let settings):
                return settings
            case .plugin(let settings):
                return settings
            }
        }

        internal mutating func updateSettings(_ newValue: Settings) {
            switch self {
            case .regular:
                self = .regular(newValue)
            case .executable:
                self = .executable(newValue)
            case .test:
                self = .test(newValue)
            case .system:
                self = .system(newValue)
            case .binary:
                self = .binary(newValue)
            case .plugin:
                self = .plugin(newValue)
            }
        }
    }
}

extension Package {
    // FIXME
    public struct RegularModule {
        var sources: String
        var resources: String
        var cSettings: String
        var cxxSettings: String
        var swiftSettings: String
        var linkerSettings: String

        internal init() {
            self.sources = ""
            self.resources = ""
            self.cSettings = ""
            self.cxxSettings = ""
            self.swiftSettings = ""
            self.linkerSettings = ""
        }
    }

    // FIXME
    public struct ExecutableModule {
        var sources: String
        var resources: String
        var cSettings: String
        var cxxSettings: String
        var swiftSettings: String
        var linkerSettings: String

        internal init() {
            self.sources = ""
            self.resources = ""
            self.cSettings = ""
            self.cxxSettings = ""
            self.swiftSettings = ""
            self.linkerSettings = ""
        }
    }

    // FIXME
    public struct TestModule {
        var sources: String
        var resources: String
        var cSettings: String
        var cxxSettings: String
        var swiftSettings: String
        var linkerSettings: String

        internal init() {
            self.sources = ""
            self.resources = ""
            self.cSettings = ""
            self.cxxSettings = ""
            self.swiftSettings = ""
            self.linkerSettings = ""
        }
    }

    public struct SystemModule {
        var providers: [String]

        internal init() {
            self.providers = []
        }
    }

    public struct BinaryModule {
        var checksum: String

        internal init(checksum: String) {
            self.checksum = checksum
        }
    }

    public struct PluginModule {
        var capability: [String]

        internal init() {
            self.capability = []
        }
    }
}
