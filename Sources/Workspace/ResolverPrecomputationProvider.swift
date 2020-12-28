/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Dispatch
import PackageModel
import PackageGraph
import TSCBasic
import TSCUtility
import SourceControl

/// Enumeration of the different errors that can arise from the `ResolverPrecomputationProvider` provider.
enum ResolverPrecomputationError: Error {
    /// Represents the error when a package was requested but couldn't be found.
    case missingPackage(package: PackageReference)

    /// Represents the error when a different requirement of a package was requested.
    case differentRequirement(
        package: PackageReference,
        state: ManagedDependency.State?,
        requirement: PackageRequirement
    )
}

/// PackageContainerProvider implementation used by Workspace to do a dependency pre-calculation using the cached
/// dependency information (Workspace.DependencyManifests) to check if dependency resolution is required before
/// performing a full resolution.
struct ResolverPrecomputationProvider: PackageContainerProvider {
    /// The package graph inputs.
    let root: PackageGraphRoot

    /// The managed manifests to make available to the resolver.
    let dependencyManifests: Workspace.DependencyManifests

    /// The dependency mirrors.
    let mirrors: DependencyMirrors

    /// The tools version currently in use.
    let currentToolsVersion: ToolsVersion

    init(
        root: PackageGraphRoot,
        dependencyManifests: Workspace.DependencyManifests,
        mirrors: DependencyMirrors,
        currentToolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion
    ) {
        self.root = root
        self.dependencyManifests = dependencyManifests
        self.mirrors = mirrors
        self.currentToolsVersion = currentToolsVersion
    }

    func getContainer(
        for identifier: PackageReference,
        skipUpdate: Bool,
        on queue: DispatchQueue,
        completion: @escaping (Result<PackageContainer, Error>) -> Void
    ) {
        queue.async {
            // Start by searching manifests from the Workspace's resolved dependencies.
            if let manifest = self.dependencyManifests.dependencies.first(where: { _, managed, _ in managed.packageRef == identifier }) {
                let container = LocalPackageContainer(
                    package: identifier,
                    manifest: manifest.manifest,
                    dependency: manifest.dependency,
                    mirrors: self.mirrors,
                    currentToolsVersion: self.currentToolsVersion
                )
                return completion(.success(container))
            }

            // Continue searching from the Workspace's root manifests.
            // FIXME: We might want to use a dictionary for faster lookups.
            if let index = self.dependencyManifests.root.packageRefs.firstIndex(of: identifier) {
                let container = LocalPackageContainer(
                    package: identifier,
                    manifest: self.dependencyManifests.root.manifests[index],
                    dependency: nil,
                    mirrors: self.mirrors,
                    currentToolsVersion: self.currentToolsVersion
                )

                return completion(.success(container))
            }

            // As we don't have anything else locally, error out.
            completion(.failure(ResolverPrecomputationError.missingPackage(package: identifier)))
        }
    }
}

private struct LocalPackageContainer: PackageContainer {
    let package: PackageReference
    let manifest: Manifest
    /// The managed dependency if the package is not a root package.
    let dependency: ManagedDependency?
    let mirrors: DependencyMirrors
    let currentToolsVersion: ToolsVersion

    // Gets the package reference from the managed dependency or computes it for root packages.
    var identifier: PackageReference {
        if let identifier = dependency?.packageRef {
            return identifier
        } else {
            let identity = PackageIdentity(url: manifest.url)
            return .root(identity: identity, path: manifest.path)
        }
    }

    func versionsAscending() throws -> [Version] {
        if let version = dependency?.state.checkout?.version {
            return [version]
        } else {
            return []
        }
    }

    func isToolsVersionCompatible(at version: Version) -> Bool {
        do {
            try manifest.toolsVersion.validateToolsVersion(currentToolsVersion, packagePath: "")
            return true
        } catch {
            return false
        }
    }
    
    func toolsVersion(for version: Version) throws -> ToolsVersion {
        return currentToolsVersion
    }

    func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        return try self.versionsDescending()
    }

    func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        // Because of the implementation of `reversedVersions`, we should only get the exact same version.
        precondition(dependency?.checkoutState?.version == version)
        return manifest.dependencyConstraints(productFilter: productFilter, mirrors: mirrors)
    }

    func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        // Return the dependencies if the checkout state matches the revision.
        if let checkoutState = dependency?.checkoutState,
            checkoutState.version == nil,
            checkoutState.revision.identifier == revision {
            return manifest.dependencyConstraints(productFilter: productFilter, mirrors: mirrors)
        }

        throw ResolverPrecomputationError.differentRequirement(
            package: self.package,
            state: self.dependency?.state,
            requirement: .revision(revision)
        )
    }

    func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        // Throw an error when the dependency is not unversioned to fail resolution.
        guard dependency?.state.isCheckout != true else {
            throw ResolverPrecomputationError.differentRequirement(
                package: package,
                state: dependency?.state,
                requirement: .unversioned
            )
        }

        return manifest.dependencyConstraints(productFilter: productFilter, mirrors: mirrors)
    }

    func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        return identifier
    }
}

private extension ManagedDependency.State {
    var checkout: CheckoutState? {
        switch self {
        case .checkout(let state):
            return state
        default:
            return nil
        }
    }
}
