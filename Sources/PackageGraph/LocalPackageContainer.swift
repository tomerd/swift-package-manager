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
public class LocalPackageContainer: PackageContainer  {
    public let identifier: PackageReference
    let mirrors: DependencyMirrors
    let manifestLoader: ManifestLoaderProtocol
    let toolsVersionLoader: ToolsVersionLoaderProtocol
    let currentToolsVersion: ToolsVersion
    let fs: FileSystem
    
    private var _manifest: Manifest? = nil
    
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
    
    private func loadManifest(completion: @escaping (Result<Manifest, Error>) -> Void) {
        // FIXME TOMER: lock
        if let manifest = _manifest {
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
                fileSystem: fs) { result in
                
                if case .success(let manifest) = result {
                    // FIXME TOMER: lock
                    self._manifest = manifest
                }
                completion(result)
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func getUnversionedDependencies(productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        self.loadManifest() { result in
            completion(result.map { $0.dependencyConstraints(productFilter: productFilter, mirrors: self.mirrors) })
        }
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion, completion: @escaping (Result<PackageReference, Error>) -> Void) {
        assert(boundVersion == .unversioned, "Unexpected bound version \(boundVersion)")
        self.loadManifest() { result in
            completion(result.map { self.identifier.with(newName: $0.name) })
        }
    }
    
    public func isToolsVersionCompatible(at version: Version, completion: @escaping (Result<Bool, Error>) -> Void) {
        fatalError("not implemented")
    }
    
    public func toolsVersion(for version: Version, completion: @escaping (Result<ToolsVersion, Error>) -> Void) {
        fatalError("not implemented")
    }
    
    public func versions(filter isIncluded: (Version) -> Bool, completion: @escaping (Result<AnySequence<Version> , Error>) -> Void) {
        fatalError("not implemented")
    }
    
    public var reversedVersions: [Version] {
        fatalError("not implemented")
    }
    
    public func getDependencies(at version: Version, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        fatalError("not implemented")
    }
    
    public func getDependencies(at revision: String, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        fatalError("not implemented")
    }
}

extension LocalPackageContainer: CustomStringConvertible  {
    public var description: String {
        return "LocalPackageContainer(\(identifier.path))"
    }
}
