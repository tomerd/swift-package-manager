public struct Package: Codable {
    public var modules: [Module]
    public var dependencies: [Dependency]
    public var minimumDeploymentTargets: [DeploymentTarget]

    public init() {
        self.modules = []
        self.dependencies = []
        self.minimumDeploymentTargets = []
    }
}
