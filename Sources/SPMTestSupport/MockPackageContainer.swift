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
    public typealias Identifier = PackageReference

    public typealias Constraint = PackageContainerConstraint

    public typealias Dependency = (container: Identifier, requirement: PackageRequirement)

    let name: Identifier

    let dependencies: [String: [Dependency]]

    public var unversionedDeps: [MockPackageContainer.Constraint] = []

    /// Contains the versions for which the dependencies were requested by resolver using getDependencies().
    public var requestedVersions: Set<Version> = []

    public var identifier: Identifier {
        return name
    }

    public let _versions: [Version]
    
    public func versions(filter isIncluded: @escaping (Version) -> Bool, completion: @escaping (Result<AnySequence<Version>, Error>) -> Void) {
        completion(.success(AnySequence(_versions.filter(isIncluded))))
    }

    public func reversedVersions(completion: @escaping (Result<[Version], Error>) -> Void) {
        completion(.success(_versions))
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        // FIXME: TOMER not thread safe!
        requestedVersions.insert(version)
        
        return getDependencies(at: version.description, productFilter: productFilter, completion: completion)
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        completion(.success(dependencies[revision]!.map { value in
            let (name, requirement) = value
            return MockPackageContainer.Constraint(container: name, requirement: requirement, products: productFilter)
        }))
    }

    public func getUnversionedDependencies(productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        completion(.success(unversionedDeps))
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion, completion: @escaping (Result<PackageReference, Error>) -> Void) {
        completion(.success(name))
    }

    public func isToolsVersionCompatible(at version: Version, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
    
    public func toolsVersion(for version: Version, completion: @escaping (Result<ToolsVersion, Error>) -> Void) {
        completion(.success(ToolsVersion.currentToolsVersion))
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
                let ref = PackageReference(identity: PackageIdentity(url: $0.container), path: "/\($0.container)")
                return (ref, .versionSet($0.versionRequirement))
            }
        }
        let ref = PackageReference(identity: PackageIdentity(url: name), path: "/\(name)")
        self.init(name: ref, dependencies: dependencies)
    }

    public init(
        name: Identifier,
        dependencies: [String: [Dependency]] = [:]
    ) {
        self.name = name
        let versions = dependencies.keys.compactMap(Version.init(string:))
        self._versions = versions.sorted().reversed()
        self.dependencies = dependencies
    }
}

public struct MockPackageContainerProvider: PackageContainerProvider {
    public let containers: [MockPackageContainer]
    public let containersByIdentifier: [PackageReference: MockPackageContainer]

    public init(containers: [MockPackageContainer]) {
        self.containers = containers
        self.containersByIdentifier = Dictionary(uniqueKeysWithValues: containers.map { ($0.identifier, $0) })
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

public extension MockPackageContainer.Constraint {
    init(container identifier: String, requirement: PackageRequirement, products: ProductFilter) {
        let ref = PackageReference(identity: PackageIdentity(url: identifier), path: "")
        self.init(container: ref, requirement: requirement, products: products)
    }

    init(container identifier: String, versionRequirement: VersionSetSpecifier, products: ProductFilter) {
        let ref = PackageReference(identity: PackageIdentity(url: identifier), path: "")
        self.init(container: ref, versionRequirement: versionRequirement, products: products)
    }
}

// FIXME: TOMER move somewhere else?
public extension PackageContainer {
    func isToolsVersionCompatible(at version: Version) throws -> Bool {
        return try tsc_await { self.isToolsVersionCompatible(at: version, completion: $0) }
    }

    func toolsVersion(for version: Version) throws -> ToolsVersion {
        return try tsc_await { self.toolsVersion(for: version, completion: $0) }
    }

    func versions(filter isIncluded: @escaping (Version) -> Bool)  throws -> AnySequence<Version> {
        return try tsc_await { self.versions(filter: isIncluded, completion: $0) }
    }

    func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        return try tsc_await { self.getDependencies(at: version, productFilter: productFilter, completion: $0) }
    }

    func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        return try tsc_await { self.getDependencies(at: revision, productFilter: productFilter, completion: $0) }
    }

    func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        return try tsc_await { self.getUnversionedDependencies(productFilter: productFilter, completion: $0) }
    }

    func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        return try tsc_await { self.getUpdatedIdentifier(at: boundVersion, completion: $0) }
    }
}

// FIXME: TOMER move somewhere else?
public extension PackageContainerProvider {
    func getContainer(for identifier: PackageReference, skipUpdate: Bool) throws -> PackageContainer {
        try tsc_await { self.getContainer(for: identifier, skipUpdate: skipUpdate, on: .global(), completion: $0)  }
    }
}
