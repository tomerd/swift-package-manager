/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Dispatch

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
public class LocalPackageContainer: PackageContainer {
    public let identifier: PackageReference
    private let mirrors: DependencyMirrors
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion
    /// The file system that shoud be used to load this package.
    private let fs: FileSystem

    private var _manifest: Manifest? = nil
    
    // FIXME: TOMER thread-safety
    private func loadManifest(completion: @escaping (Result<Manifest, Error>) -> Void)  {
        if let manifest = self._manifest {
            return completion(.success(manifest))
        }

        do {
            // Load the tools version.
            let toolsVersion = try toolsVersionLoader.load(at: AbsolutePath(identifier.path), fileSystem: fs)

            // Validate the tools version.
            try toolsVersion.validateToolsVersion(self.currentToolsVersion, packagePath: identifier.path)

            // Load the manifest.
            manifestLoader.load(
                package: AbsolutePath(identifier.path),
                baseURL: identifier.path,
                version: nil,
                toolsVersion: toolsVersion,
                packageKind: identifier.kind,
                fileSystem: fs,
                on: .global()) { result in
                
                if case .success(let manifest) = result {
                    self._manifest = manifest
                }
                completion(result)
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func getUnversionedDependencies(productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        loadManifest() { result in
            completion(result.map { $0.dependencyConstraints(productFilter: productFilter, mirrors: self.mirrors) })
        }
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion, completion: @escaping (Result<PackageReference, Error>) -> Void) {
        assert(boundVersion == .unversioned, "Unexpected bound version \(boundVersion)")
        loadManifest() { result in
            completion(result.map { self.identifier.with(newName: $0.name) })
        }
    }

    public init(
        _ identifier: PackageReference,
        mirrors: DependencyMirrors,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion,
        fs: FileSystem = localFileSystem
    ) {
        assert(URL.scheme(identifier.path) == nil, "unexpected scheme \(URL.scheme(identifier.path)!) in \(identifier.path)")
        self.identifier = identifier
        self.mirrors = mirrors
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
        self.fs = fs
    }
    
    public func isToolsVersionCompatible(at version: Version, completion: @escaping (Result<Bool, Error>) -> Void) {
        fatalError("This should never be called")
    }
    
    public func toolsVersion(for version: Version, completion: @escaping (Result<ToolsVersion, Error>) -> Void) {
        fatalError("This should never be called")
    }
    
    public func versions(filter isIncluded: (Version) -> Bool, completion: @escaping (Result<AnySequence<Version>, Error>) -> Void) {
        fatalError("This should never be called")
    }
    
    public func reversedVersions(completion: @escaping (Result<[Version], Error>) -> Void) {
        fatalError("This should never be called")
    }
    
    public func getDependencies(at version: Version, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        fatalError("This should never be called")
    }
    
    public func getDependencies(at revision: String, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        fatalError("This should never be called")
    }
}

extension LocalPackageContainer: CustomStringConvertible  {
    public var description: String {
        return "LocalPackageContainer(\(identifier.path))"
    }
}
