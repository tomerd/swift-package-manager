extension Package {
    public struct DeploymentTarget {
        let platform: Platform
        let version: String?
    }

    public struct Platform {
        let name: String
    }
}
