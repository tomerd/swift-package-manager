public protocol AnyDependency {
    var underlying: Dependency { get set }
}

public struct Local: AnyDependency {
    public var underlying: Dependency

    public init(_ identity: Dependency.Identity, at path: String) {
        self.underlying = Dependency(identity: identity, kind: .local(.init(path: path)))
    }
}

public struct Remote: AnyDependency {
    public var underlying: Dependency

    public init(_ identity: Dependency.Identity, branch: String) {
        self.underlying = Dependency(identity: identity, kind: .remote(.init(requirement: .branch(branch))))
    }

    public init(_ identity: Dependency.Identity, upToNextMajor: Dependency.Version) {
        let previous = Dependency.Version(max(0, upToNextMajor.major - 1), 0, 0)
        self.underlying = Dependency(identity: identity, kind: .remote(.init(requirement: .range(previous..<upToNextMajor))))
    }
}
