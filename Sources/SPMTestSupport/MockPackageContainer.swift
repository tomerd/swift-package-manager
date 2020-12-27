/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */
import Dispatch
import XCTest

import PackageGraph
import PackageModel
import SourceControl
import TSCBasic

import struct TSCUtility.Version

public class MockPackageContainer: PackageContainer {
    public typealias Constraint = PackageContainerConstraint

    public typealias Dependency = (container: PackageReference, requirement: PackageRequirement)

    let name: PackageReference

    let dependencies: [String: [Dependency]]

    public var unversionedDeps: [MockPackageContainer.Constraint] = []

    /// Contains the versions for which the dependencies were requested by resolver using getDependencies().
    public var requestedVersions: Set<Version> = []

    public var package: PackageReference {
        return self.name
    }

    public let _versions: [Version]
    public func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        return try self.versionsDescending()
    }

    public func versionsAscending() throws -> [Version] {
        return _versions
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter) -> [MockPackageContainer.Constraint] {
        requestedVersions.insert(version)
        return getDependencies(at: version.description, productFilter: productFilter)
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter) -> [MockPackageContainer.Constraint] {
        return dependencies[revision]!.map { package, requirement in
            return MockPackageContainer.Constraint(package: package, requirement: requirement, products: productFilter)
        }
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) -> [MockPackageContainer.Constraint] {
        return unversionedDeps
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        return name
    }

    public func isToolsVersionCompatible(at version: Version) -> Bool {
        return true
    }
    
    public func toolsVersion(for version: Version) throws -> ToolsVersion {
        return ToolsVersion.currentToolsVersion
    }

    public var isRemoteContainer: Bool? {
        return true
    }

    public convenience init(
        name: String,
        dependenciesByVersion: [Version: [(container: String, versionRequirement: VersionSetSpecifier)]]
    ) {
        var dependencies: [String: [Dependency]] = [:]
        for (version, deps) in dependenciesByVersion {
            dependencies[version.description] = deps.map {
                let ref = PackageReference(identity: PackageIdentity2($0.container), kind: .remote, path: "/\($0.container)")
                return (ref, .versionSet($0.versionRequirement))
            }
        }
        let ref = PackageReference(identity: PackageIdentity2(name), kind: .remote, path: "/\(name)")
        self.init(name: ref, dependencies: dependencies)
    }

    public init(
        name: PackageReference,
        dependencies: [String: [Dependency]] = [:]
    ) {
        self.name = name
        self._versions = dependencies.keys.compactMap(Version.init(string:)).sorted()
        self.dependencies = dependencies
    }
}

public struct MockPackageContainerProvider: PackageContainerProvider {
    public let containers: [MockPackageContainer]
    public let containersByIdentifier: [PackageReference: MockPackageContainer]

    public init(containers: [MockPackageContainer]) {
        self.containers = containers
        self.containersByIdentifier = Dictionary(uniqueKeysWithValues: containers.map { ($0.package, $0) })
    }

    public func getContainer(
        for identifier: PackageReference,
        skipUpdate: Bool,
        on queue: DispatchQueue,
        completion: @escaping (Result<PackageContainer, Swift.Error>
        ) -> Void
    ) {
        queue.async {
            completion(self.containersByIdentifier[identifier].map { .success($0) } ??
                .failure(StringError("unknown module \(identifier)")))
        }
    }
}

/*
public extension MockPackageContainer.Constraint {
    init(container identifier: String, requirement: PackageRequirement, products: ProductFilter) {
        let ref = PackageReference(identity: PackageIdentity2(identifier), kind: .remote, path: "")
        self.init(package: ref, requirement: requirement, products: products)
    }

    init(container identifier: String, versionRequirement: VersionSetSpecifier, products: ProductFilter) {
        let ref = PackageReference(identity: PackageIdentity2(identifier), kind: .remote, path: "")
        self.init(package: ref, versionRequirement: versionRequirement, products: products)
    }
}
*/
