extension Package {
    public typealias Identity = String
}

extension Package {
    public struct Dependency {
        public let identity: Identity
        public let kind: Kind
    }
}

extension Package.Dependency {
    public enum Kind {
        case local(path: String)
        case remote(requirement: Requirement, gitURL: String? = nil)
    }
}

extension Package.Dependency {
    public enum Requirement {
        case exact(Version)
        case range(Range<Version>)
        case revision(String)
        case branch(String)
    }
}
