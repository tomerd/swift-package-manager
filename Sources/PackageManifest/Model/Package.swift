public struct Package {
    public var dependencies: [Dependency]
    public var modules: [PackageModule]
    public var minimumDeploymentTargets: [DeploymentTarget]?
}
