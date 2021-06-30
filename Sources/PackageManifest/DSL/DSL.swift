extension Package {
    /*public init(@DependenciesBuilder _ dependenciesBuilder: () -> [Package.Dependency]/*,
                @ModulesBuilder _ modulesBuilder: () -> [Package.Module]*/
    ) {
        let dependencies = dependenciesBuilder()
        let modules = [Module]() //modulesBuilder()
        self.init(dependencies: dependencies, modules: modules)
    }*/

    /*
    public init(_ dependencies: Dependencies) {
        self.init(dependencies: dependencies.dependencies, modules: [])
    }*/

    public init() {
        self.dependencies = []
        self.modules = []
        self.minimumDeploymentTargets = nil
    }
}

extension Package {
    public func dependencies(@DependenciesBuilder _ builder: () -> [Package.Dependency]) -> Package {
        return Self(
            dependencies: builder(),
            modules: self.modules,
            minimumDeploymentTargets: self.minimumDeploymentTargets
        )
    }
}

extension Package {
    public func modules(@ModulesBuilder _ builder: () -> [PackageModule]) -> Package {
        return Self(
            dependencies: self.dependencies,
            modules: builder(),
            minimumDeploymentTargets: self.minimumDeploymentTargets
        )
    }
}

extension Package {
    public func minimumDeploymentTarget(@DeploymentTargetsBuilder _ builder: () -> [Package.DeploymentTarget]) -> Package {
        return Self(
            dependencies: self.dependencies,
            modules: self.modules,
            minimumDeploymentTargets: builder()
        )
    }
}

@resultBuilder
public enum DependenciesBuilder {
    public static func buildExpression(_ element: Package.Dependency) -> [Package.Dependency] {
        return [element]
    }

    public static func buildOptional(_ component: [Package.Dependency]?) -> [Package.Dependency] {
        guard let component = component else { return [] }
        return component
    }

    public static func buildEither(first component: [Package.Dependency]) -> [Package.Dependency] {
        return component
    }

    public static func buildEither(second component: [Package.Dependency]) -> [Package.Dependency] {
        return component
    }

    public static func buildArray(_ components: [[Package.Dependency]]) -> [Package.Dependency] {
        return components.flatMap{ $0 }
    }

    public static func buildBlock(_ components: [Package.Dependency]...) -> [Package.Dependency] {
        return components.flatMap{ $0 }
    }
}

@resultBuilder
public enum ModulesBuilder {
    public static func buildExpression(_ element: PackageModule) -> [PackageModule] {
        return [element]
    }

    public static func buildOptional(_ component: [PackageModule]?) -> [PackageModule] {
        guard let component = component else { return [] }
        return component
    }

    public static func buildEither(first component: [PackageModule]) -> [PackageModule] {
        return component
    }

    public static func buildEither(second component: [PackageModule]) -> [PackageModule] {
        return component
    }

    public static func buildArray(_ components: [[PackageModule]]) -> [PackageModule] {
        return components.flatMap{ $0 }
    }

    public static func buildBlock(_ components: [PackageModule]...) -> [PackageModule] {
        return components.flatMap{ $0 }
    }
}

@resultBuilder
public enum DeploymentTargetsBuilder {
    public static func buildExpression(_ element: Package.DeploymentTarget) -> [Package.DeploymentTarget] {
        return [element]
    }

    public static func buildOptional(_ component: [Package.DeploymentTarget]?) -> [Package.DeploymentTarget] {
        guard let component = component else { return [] }
        return component
    }

    public static func buildEither(first component: [Package.DeploymentTarget]) -> [Package.DeploymentTarget] {
        return component
    }

    public static func buildEither(second component: [Package.DeploymentTarget]) -> [Package.DeploymentTarget] {
        return component
    }

    public static func buildArray(_ components: [[Package.DeploymentTarget]]) -> [Package.DeploymentTarget] {
        return components.flatMap{ $0 }
    }

    public static func buildBlock(_ components: [Package.DeploymentTarget]...) -> [Package.DeploymentTarget] {
        return components.flatMap{ $0 }
    }
}

// ****************************************************************

extension Package.Dependency {

    /*public static func LocalDependency(identity: Package.Identity, at path: String) -> Self {
        .init(identity: identity, kind: .local(path: path))
    }*/

    public init(_ identity: Package.Identity) {
        self.init(identity: identity, kind: .remote(requirement: .branch("main")))
    }

    public func local(at path: String) -> Package.Dependency {
        Self.init(identity: self.identity, kind: .local(path: path))
    }

    public func branch(_ name: String) -> Package.Dependency {
        Self.init(identity: self.identity, kind: .remote(requirement: .branch(name)))
    }

    public func upToNextMajor(_ version: Version) -> Package.Dependency {
        let previous = Version(max(0, version.major - 1), 0, 0)
        return Self.init(identity: self.identity, kind: .remote(requirement: .range(previous..<version)))
    }
}

public func Local(_ identity: Package.Identity, at path: String) -> Package.Dependency  {
    return .init(identity: identity, kind: .local(path: path))
}

public func Remote(_ identity: Package.Identity, branch: String) -> Package.Dependency  {
    return .init(identity: identity, kind: .remote(requirement: .branch(branch)))
}

public func Remote(_ identity: Package.Identity, upToNextMajor: Package.Dependency.Version) -> Package.Dependency  {
    let previous = Package.Dependency.Version(max(0, upToNextMajor.major - 1), 0, 0)
    return .init(identity: identity, kind: .remote(requirement: .range(previous..<upToNextMajor)))
}


/*
public func Branch(_ identity: Package.Identity, _ branch: String) -> Package.Dependency  {
    return .init(identity: identity, kind: .remote(requirement: .branch(branch)))
}

public func UpToNextMajor(_ identity: Package.Identity, _ version: Package.Dependency.Version) -> Package.Dependency  {
    let previous = Package.Dependency.Version(max(0, version.major - 1), 0, 0)
    return .init(identity: identity, kind: .remote(requirement: .range(previous..<version)))
}
*/

// ****************************************************************

/*
extension Package.Module {
    public init(_ name: String) {
        self.init(name: name, kind: .regular)
    }
}
*/

extension Package.Module {
    public func path(_ path: String) -> Self {
        .init(name: self.name, kind: self.kind, path: path)
    }
}

/*
 extension Package.Module {
    public static func plugin(_ name: String) -> Self {
        Self.init(name: name, kind: .plugin)
    }
    public static func binary(_ name: String) -> Self {
        Self.init(name: name, kind: .binary)
    }
}*/

public func Module(_ name: String) -> Package.Module<Package.RegularModule>  {
    .init(name: name, kind: .regular(.init()))
}


public func Test(_ name: String) -> Package.Module<Package.TestModule>  {
    .init(name: name, kind: .test(.init()))
}

public func Plugin(_ name: String) -> Package.Module<Package.PluginModule>  {
    .init(name: name, kind: .plugin(.init()))
}

public func Binary(_ name: String, checksum: String) -> Package.Module<Package.BinaryModule>  {
    .init(name: name,
          kind: .binary(
            .init(checksum: checksum)
          )
    )
}


extension Package.Module where Settings == Package.RegularModule  {
    public func cxxSettings(_ value: String) -> Self {
        var module = self
        var settings = self.kind.settings
        settings.cxxSettings = value
        module.kind.updateSettings(settings)
        return module
    }
}

extension Package.Module where Settings == Package.TestModule  {
    public func cxxSettings(_ value: String) -> Self {
        var module = self
        var settings = self.kind.settings
        settings.cxxSettings = value
        module.kind.updateSettings(settings)
        return module
    }
}


// ****************************************************************

extension Package.DeploymentTarget {
    public static func macOS(_ version: String? = nil) -> Self {
        self.init(platform: .init(name: "macOS"), version: version)
    }
    public static func iOS(_ version: String? = nil) -> Self {
        self.init(platform: .init(name: "iOS"), version: version)
    }
}


public func MacOS(_ version: String? = nil) -> Package.DeploymentTarget  {
    .init(platform: .init(name: "macOS"), version: version)
}

public func iOS(_ version: String? = nil) -> Package.DeploymentTarget  {
    .init(platform: .init(name: "iOS"), version: version)
}
