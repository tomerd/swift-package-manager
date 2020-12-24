/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Dispatch

import Basics
import TSCBasic
import PackageLoading
import PackageModel
import SourceControl
import TSCUtility

/// Local package container.
///
/// This class represent packages that are referenced locally in the file system.
/// There is no need to perform any git operations on such packages and they
/// should be used as-is. Infact, they might not even have a git repository.
/// Examples: Root packages, local dependencies, edited packages.
public struct LocalPackageContainer: PackageContainer {
    public let underlying: PackageReference
    private let mirrors: DependencyMirrors
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion

    /// The file system that shoud be used to load this package.
    private let fs: FileSystem

    /// cached version of the manifest
    private let manifest = ThreadSafeBox<Manifest>()

    private func loadManifest() throws -> Manifest {
        try manifest.memoize() {
            // Load the tools version.
            let toolsVersion = try toolsVersionLoader.load(at: AbsolutePath(self.underlying.path), fileSystem: fs)

            // Validate the tools version.
            try toolsVersion.validateToolsVersion(self.currentToolsVersion, packagePath: self.underlying.path)

            // Load the manifest.
            // FIXME: this should not block
            return try temp_await {
                manifestLoader.load(packageIdentity: self.underlying.identity,
                                    packageKind: self.underlying.kind,
                                    at: AbsolutePath(self.underlying.path),
                                    url: self.underlying.path,
                                    version: nil,
                                    toolsVersion: toolsVersion,
                                    fileSystem: fs,
                                    on: .global(),
                                    completion: $0)
            }
        }
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        return try loadManifest().dependencyConstraints(productFilter: productFilter, mirrors: mirrors)
    }

    /*public func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        assert(boundVersion == .unversioned, "Unexpected bound version \(boundVersion)")
        let manifest = try loadManifest()
        return self.underlying.with(newName: manifest.name)
    }*/

    public init(
        package: PackageReference,
        mirrors: DependencyMirrors,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion,
        fs: FileSystem = localFileSystem
    ) {
        assert(URL.scheme(package.path) == nil, "unexpected scheme \(URL.scheme(package.path)!) in \(package.path)")
        self.underlying = package
        self.mirrors = mirrors
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
        self.fs = fs
    }
    
    public func isToolsVersionCompatible(at version: Version) -> Bool {
        fatalError("This should never be called")
    }
    
    public func toolsVersion(for version: Version) throws -> ToolsVersion {
        fatalError("This should never be called")
    }
    
    public func toolsVersionsAppropriateVersionsDescending() throws -> [Version] {
        fatalError("This should never be called")
    }
    
    public func versionsAscending() throws -> [Version] {
        fatalError("This should never be called")
    }
    
    public func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        fatalError("This should never be called")
    }
    
    public func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        fatalError("This should never be called")
    }
}

extension LocalPackageContainer: CustomStringConvertible  {
    public var description: String {
        return "LocalPackageContainer(\(self.underlying.path))"
    }
}
