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
public final class LocalPackageContainer: PackageContainer {
    @available(*, deprecated)
    public var identifier: PackageReference {
        get {
            self.package
        }
    }

    public let package: PackageReference

    //private let mirrors: DependencyMirrors
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion

    /// The file system that shoud be used to load this package.
    private let fileSystem: FileSystem

    private let diagnostics: DiagnosticsEngine

    /// cached version of the manifest
    private let manifestCache = ThreadSafeBox<Manifest>()

    private func loadManifest() throws -> Manifest {
        try manifestCache.memoize() {
            let manifestPath: AbsolutePath
            switch self.package.kind {
            case .local(let path),
                 .root(let path):
                manifestPath = path
            case .remote(let url):
                throw InternalError("unexpected remote package \(url)")
            }
            // Load the tools version.
            let toolsVersion = try toolsVersionLoader.load(at: manifestPath, fileSystem: self.fileSystem)

            // Validate the tools version.
            try toolsVersion.validateToolsVersion(self.currentToolsVersion, packagePath: manifestPath.pathString)

            // Load the manifest.
            // FIXME: this should not block
            return try temp_await {
                manifestLoader.load(packageIdentity: self.package.identity,
                                    packageKind: self.package.kind,
                                    at: manifestPath,
                                    //baseURL: self.package.path,
                                    version: nil,
                                    toolsVersion: toolsVersion,
                                    fileSystem: self.fileSystem,
                                    diagnostics: self.diagnostics,
                                    on: .global(),
                                    completion: $0)
            }
        }
    }

    public func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        return try loadManifest().dependencyConstraints(productFilter: productFilter)
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> PackageReference {
        assert(boundVersion == .unversioned, "Unexpected bound version \(boundVersion)")
        let manifest = try self.loadManifest()
        return self.package.with(newName: manifest.name)
    }

    public init(
        package: PackageReference,
        //mirrors: DependencyMirrors,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion,
        fileSystem: FileSystem, // = localFileSystem,
        diagnostics: DiagnosticsEngine
    ) {
        assert(!package.kind.isRemote(), "unexpected remote package \(package.identity)")
        self.package = package
        //self.mirrors = mirrors
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
        self.fileSystem = fileSystem
        self.diagnostics = diagnostics
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
        return "LocalPackageContainer(\(self.package.location))"
    }
}
