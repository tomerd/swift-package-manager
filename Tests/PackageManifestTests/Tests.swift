import PackageManifest
import XCTest

final class PackageManifestTests: XCTestCase {

    func test1() {
        let package = Package()
            .minimumDeploymentTarget {
                MacOS("10.15")
                iOS("12.0")
            }
            .modules {
                Library("module-standard")
                    .path("custom/path")
                    .cxxSettings(["cxxSettings"])
                    .public()
                if ProcessInfo.processInfo.environment["condition"] == "true" {
                    Test("module-test")
                        .sources(["sources-1"])
                        .exclude(["exclude-1", "exclude-2"])
                        .cxxSettings(["cxxSettings"])
                }
                Plugin("module-plugin", capability: .buildTool)
                    .path("custom/path")
                #if os(macOS)
                Binary("module-binary", url: "url", checksum: "checksum")
                    .public()
                    .explicitDependencies(["foo", "bar"])
                #endif
            }
            .dependencies {
                Local("local", at: "foo")
                if ProcessInfo.processInfo.environment["condition"] == "true" {
                    Remote("remote-major-1", upToNextMajor: "1.0.0")
                } else {
                    Remote("remote-major-2", upToNextMajor: "2.0.0")
                }
                Remote("remote-branch", branch: "main")
            }


        // *******

        print(package)

    }

    func test2() {
var package = Package()

var librarySettings = Module.LibrarySettings()
librarySettings.swiftSettings = ["swiftSettings"]
var library = Module(name: "my-lib", kind: .library(librarySettings))
library.path = "/some-path"
package.modules.append(library)

var executableSettings = Module.ExecutableSettings()
executableSettings.sources = ["file1.swift"]
let executable = Module(name: "my-exec", kind: .executable(executableSettings))
package.modules.append(executable)

let dependencySettings = Dependency.RemoteSettings(requirement: .range("1.0.0" ..< "2.0.0"))
let dependency = Dependency(identity: "apple/swift-nio", kind: .remote(dependencySettings))
package.dependencies.append(dependency)

package.minimumDeploymentTargets.append(DeploymentTarget(platform: .macOS, version: "12.0"))

        // *******

        print(package)
    }
}
