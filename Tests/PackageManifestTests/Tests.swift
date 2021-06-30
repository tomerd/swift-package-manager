import PackageManifest
import XCTest

final class PackageManifestTests: XCTestCase {

    func testMe() {

        let package = Package()
            .minimumDeploymentTarget {
                MacOS("10.15")
                iOS("12.0")
            }
            .modules {
                Module("module-standard")
                    .cxxSettings("cxxSettings")
                Test("module-test")
                    .cxxSettings("cxxSettings")
                Plugin("module-plugin")
                    .path("custom/path")
                Binary("module-binary", checksum: "checksum")
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

        for module in package.modules {
            print("\(module.name) \(module.kind)")
        }

        for dependency in package.dependencies {
            print("\(dependency.identity) \(dependency.kind)")
        }



    }
}
