public protocol AnyModule {
    var underlying: Module { get set }
}

extension AnyModule {
    public func path(_ path: String) -> Self {
        var module = self
        module.underlying.path = path
        return module
    }

    public func explicitDependencies(_ dependencies: [String]) -> Self {
        var module = self
        module.underlying.dependencies = dependencies
        return module
    }
}

// MARK: - Sources Module (base abstraction)

public protocol SourcesModule: AnyModule {
    associatedtype Settings: SourceModuleSettings
    var settings: Settings { get set }
}

extension SourcesModule  {
    public func sources(_ value: [String]) -> Self {
        var module = self
        module.settings.sources = value
        return module
    }

    public func exclude(_ value: [String]) -> Self {
        var module = self
        module.settings.exclude = value
        return module
    }

    public func swiftSettings(_ value: [String]) -> Self {
        var module = self
        module.settings.swiftSettings = value
        return module
    }

    public func cSettings(_ value: [String]) -> Self {
        var module = self
        module.settings.cSettings = value
        return module
    }

    public func cxxSettings(_ value: [String]) -> Self {
        var module = self
        module.settings.cxxSettings = value
        return module
    }
}

// MARK: - Library Module

public struct Library: SourcesModule {
    public var underlying: Module

    public init(_ name: String) {
        self.underlying = Module(name: name, kind: .library(.init()))
    }

    public var settings: Module.LibrarySettings {
        get {
            guard case .library(let settings) = self.underlying.kind else {
                preconditionFailure()
            }
            return settings
        }
        set {
            self.underlying.kind = .library(newValue)
        }
    }

    public func `public`(linkage: Module.LibrarySettings.Linkage = .auto) -> Self {
        var module = self
        module.settings.isPublic = true
        module.settings.linkage = linkage
        return module
    }

}

// MARK: - Executable Module

public struct Executable: SourcesModule {
    public var underlying: Module

    public init(_ name: String) {
        self.underlying = Module(name: name, kind: .executable(.init()))
    }

    public var settings: Module.ExecutableSettings {
        get {
            guard case .executable(let settings) = self.underlying.kind else {
                preconditionFailure()
            }
            return settings
        }
        set {
            self.underlying.kind = .executable(newValue)
        }
    }
}

// MARK: - Test Module

public struct Test: SourcesModule {
    public var underlying: Module

    public init(_ name: String) {
        self.underlying = Module(name: name, kind: .test(.init()))
    }

    public var settings: Module.TestSettings {
        get {
            guard case .test(let settings) = self.underlying.kind else {
                preconditionFailure()
            }
            return settings
        }
        set {
            self.underlying.kind = .test(newValue)
        }
    }
}

// MARK: - Binary Module

public struct Binary: AnyModule {
    public var underlying: Module

    public init(_ name: String, path: String) {
        self.underlying = Module(
            name: name,
            kind: .binary(
                .init(path: path)
            )
        )
    }

    public init(_ name: String, url: String, checksum: String) {
        self.underlying = Module(
            name: name,
            kind: .binary(
                .init(url: url, checksum: checksum)
            )
        )
    }

    var settings: Module.BinarySettings {
        get {
            guard case .binary(let settings) = self.underlying.kind else {
                preconditionFailure()
            }
            return settings
        }
        set {
            self.underlying.kind = .binary(newValue)
        }
    }

    public func `public`() -> Self {
        var module = self
        module.settings.isPublic = true
        return module
    }
}

// MARK: - Plugin Module

public struct Plugin: AnyModule {
    public var underlying: Module

    public init(_ name: String, capability: Module.PluginSettings.Capability) {
        self.underlying = Module(
            name: name,
            kind: .plugin(
                .init(capability: capability)
            )
        )
    }
}


