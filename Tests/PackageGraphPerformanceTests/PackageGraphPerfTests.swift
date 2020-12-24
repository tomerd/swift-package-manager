/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import PackageGraph
import PackageModel
import SPMTestSupport

class PackageGraphPerfTests: XCTestCasePerf {

    func testLoading100Packages() throws {
      #if os(macOS)
        let N = 100
        let files = (1...N).map { "/Foo\($0)/source.swift" }
        let fs = InMemoryFileSystem(emptyFiles: files)
        
        var externalManifests = [PackageIdentity2: (AbsolutePath, Manifest)]()
      var rootManifests: [AbsolutePath: Manifest]!
        for pkg in 1...N {
            let name = "Foo\(pkg)"
            let url = "/" + name

            let dependencies: [PackageDependencyDescription]
            let targets: [TargetDescription]
            // Create package.
            if pkg == N {
                dependencies = []
                targets = [TargetDescription(name: name, path: ".")]
            } else {
                let depName = "Foo\(pkg + 1)"
                let depUrl = URL(string: "/\(depName)")!
                dependencies = [PackageDependencyDescription(identity: PackageIdentity2(depName), location: depUrl, requirement: .upToNextMajor(from: "1.0.0"))]
                targets = [TargetDescription(name: name, dependencies: [.byName(name: depName, condition: nil)], path: ".")]
            }
            // Create manifest.
            let isRoot = pkg == 1
            let path = AbsolutePath(url).appending(component: Manifest.filename)
            let manifest = Manifest(
                name: name,
                platforms: [],
                path: path,
                url: url,
                version: "1.0.0",
                toolsVersion: .v4_2,
                packageKind: isRoot ? .root : .remote,
                dependencies: dependencies,
                products: [
                    ProductDescription(name: name, type: .library(.automatic), targets: [name])
                ],
                targets: targets
            )
            if isRoot {
                rootManifests[path] = manifest
            } else {
                let id = PackageIdentity2(name)
                externalManifests[id] = (path, manifest)
            }
        }
        
        measure {
            let diagnostics = DiagnosticsEngine()
            let g = try! PackageGraph.load(
                root: PackageGraphRoot(input: PackageGraphRootInput(manifests: rootManifests)),
                externalManifests: externalManifests,
                diagnostics: diagnostics,
                fileSystem: fs)
            XCTAssertEqual(g.packages.count, N)
            XCTAssertNoDiagnostics(diagnostics)
        }
      #endif
    }
}
