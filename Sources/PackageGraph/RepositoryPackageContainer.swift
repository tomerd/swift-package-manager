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

enum RepositoryPackageResolutionError: Swift.Error {
    /// A requested repository could not be cloned.
    case unavailableRepository
}

public typealias RepositoryPackageConstraint = PackageContainerConstraint

/// Adaptor to expose an individual repository as a package container.
public class RepositoryPackageContainer: BasePackageContainer, CustomStringConvertible {

    // A wrapper for getDependencies() errors. This adds additional information
    // about the container to identify it for diagnostics.
    public struct GetDependenciesError: Error, CustomStringConvertible, DiagnosticLocationProviding {

        /// The container (repository) that encountered the error.
        public let containerIdentifier: String

        /// The source control reference (version, branch, revision, etc) that was involved.
        public let reference: String

        /// The actual error that occurred.
        public let underlyingError: Error
        
        /// Optional suggestion for how to resolve the error.
        public let suggestion: String?
        
        public var diagnosticLocation: DiagnosticLocation? {
            return PackageLocation.Remote(url: containerIdentifier, reference: reference)
        }
        
        /// Description shown for errors of this kind.
        public var description: String {
            var desc = "\(underlyingError) in \(containerIdentifier)"
            if let suggestion = suggestion {
                desc += " (\(suggestion))"
            }
            return desc
        }
    }

    /// This is used to remember if tools version of a particular version is
    /// valid or not.
    public private(set) var validToolsVersionsCache: [Version: Bool] = [:]

    /// The available version list (in reverse order).
    public override func versions(filter isIncluded: (Version) -> Bool) -> AnySequence<Version> {
        return AnySequence(_reversedVersions.filter(isIncluded).lazy.filter({
            // If we have the result cached, return that.
            if let result = self.validToolsVersionsCache[$0] {
                return result
            }

            // Otherwise, compute and cache the result.
            let isValid = (try? self.toolsVersion(for: $0)).flatMap(self.isValidToolsVersion(_:)) ?? false
            self.validToolsVersionsCache[$0] = isValid
            return isValid
        }))
    }

    public override var reversedVersions: [Version] { _reversedVersions }

    /// The opened repository.
    let repository: Repository

    /// The versions in the repository and their corresponding tags.
    let knownVersions: [Version: String]

    /// The versions in the repository sorted by latest first.
    let _reversedVersions: [Version]

    /// Caches
    private var dependenciesCache: [String: [ProductFilter: (Manifest, [RepositoryPackageConstraint])]] = [:]
    private let dependenciesCacheLock = Lock()
    
    private var revisionsCache: [String: Revision] = [:]
    private let revisionsCacheLock = Lock()
    
    private var toolsVersionCache: [Version: ToolsVersion] = [:]
    private let toolsVersionCacheLock = Lock()
    
    private var manifestCache: [Revision: Manifest] = [:]
    private let manifestCacheLock = Lock()
    
    init(
        identifier: PackageReference,
        mirrors: DependencyMirrors,
        repository: Repository,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion
    ) {
        self.repository = repository

        // Compute the map of known versions.
        //
        // FIXME: Move this utility to a more stable location.
        let knownVersionsWithDuplicates = Git.convertTagsToVersionMap(repository.tags)

        let knownVersions = knownVersionsWithDuplicates.mapValues({ tags -> String in
            if tags.count == 2 {
                // FIXME: Warn if the two tags point to different git references.
                return tags.first(where: { !$0.hasPrefix("v") })!
            }
            assert(tags.count == 1, "Unexpected number of tags")
            return tags[0]
        })

        self.knownVersions = knownVersions
        self._reversedVersions = [Version](knownVersions.keys).sorted().reversed()
        super.init(
            identifier,
            mirrors: mirrors,
            manifestLoader: manifestLoader,
            toolsVersionLoader: toolsVersionLoader,
            currentToolsVersion: currentToolsVersion
        )
    }

    public var description: String {
        return "RepositoryPackageContainer(\(identifier.repository.url.debugDescription))"
    }

    public override var isRemoteContainer: Bool? {
        return true
    }

    public func getTag(for version: Version) -> String? {
        return knownVersions[version]
    }

    /// Returns revision for the given tag.
    public func getRevision(forTag tag: String) throws -> Revision {
        return try self.revisionsCache.memo(key: tag, lock: self.revisionsCacheLock) {
            try repository.resolveRevision(tag: tag)
        }
    }

    /// Returns revision for the given identifier.
    public func getRevision(forIdentifier identifier: String) throws -> Revision {
        return try self.revisionsCache.memo(key: identifier, lock: self.revisionsCacheLock) {
            try repository.resolveRevision(identifier: identifier)
        }
    }

    /// Returns the tools version of the given version of the package.
    public override func toolsVersion(for version: Version) throws -> ToolsVersion {
        return try self.toolsVersionCache.memo(key: version, lock: self.toolsVersionCacheLock) {
            let tag = knownVersions[version]!
            let revision = try self.getRevision(forTag: tag)
            let fs = try repository.openFileView(revision: revision)
            return try toolsVersionLoader.load(at: .root, fileSystem: fs)
        }
    }

    public override func getDependencies(at version: Version, productFilter: ProductFilter) throws -> [RepositoryPackageConstraint] {
        do {
            return try cachedDependencies(forIdentifier: version.description, productFilter: productFilter) {
                let tag = knownVersions[version]!
                let revision = try self.getRevision(forTag: tag)
                return try getDependencies(at: revision, version: version, productFilter: productFilter)
            }.1
        } catch {
            throw GetDependenciesError(
                containerIdentifier: identifier.repository.url, reference: version.description, underlyingError: error, suggestion: nil)
        }
    }

    public override func getDependencies(at revision: String, productFilter: ProductFilter) throws -> [RepositoryPackageConstraint] {
        do {
            return try cachedDependencies(forIdentifier: revision, productFilter: productFilter) {
                // resolve the revision identifier and return its dependencies.
                let revision = try self.getRevision(forIdentifier: revision)
                return try getDependencies(at: revision, productFilter: productFilter)
            }.1
        } catch {
            // Examine the error to see if we can come up with a more informative and actionable error message.  We know that the revision is expected to be a branch name or a hash (tags are handled through a different code path).
            if let error = error as? GitRepositoryError, error.description.contains("Needed a single revision") {
                // It was a Git process invocation error.  Take a look at the repository to see if we can come up with a reasonable diagnostic.
                if let rev = try? self.getRevision(forIdentifier: revision), repository.exists(revision: rev) {
                    // Revision does exist, so something else must be wrong.
                    throw GetDependenciesError(
                        containerIdentifier: identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
                }
                else {
                    // Revision does not exist, so we customize the error.
                    let sha1RegEx = try! RegEx(pattern: #"\A[:xdigit:]{40}\Z"#)
                    let isBranchRev = sha1RegEx.matchGroups(in: revision).compactMap{ $0 }.isEmpty
                    let errorMessage = "could not find " + (isBranchRev ? "a branch named ‘\(revision)’" : "the commit \(revision)")
                    let mainBranchExists = (try? self.getRevision(forIdentifier: "main")) != nil
                    let suggestion = (revision == "master" && mainBranchExists) ? "did you mean ‘main’?" : nil
                    throw GetDependenciesError(
                        containerIdentifier: identifier.repository.url, reference: revision,
                        underlyingError: StringError(errorMessage), suggestion: suggestion)
                }
            }
            // If we get this far without having thrown an error, we wrap and throw the underlying error.
            throw GetDependenciesError(containerIdentifier: identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
        }
    }

    private func cachedDependencies(
        forIdentifier identifier: String,
        productFilter: ProductFilter,
        getDependencies: () throws -> (Manifest, [RepositoryPackageConstraint])
    ) throws -> (Manifest, [RepositoryPackageConstraint]) {
        return try dependenciesCacheLock.withLock {
            if let result = dependenciesCache[identifier, default: [:]][productFilter] {
                return result
            }
            let result = try getDependencies()
            dependenciesCache[identifier, default: [:]][productFilter] = result
            return result
        }
    }

    /// Returns dependencies of a container at the given revision.
    private func getDependencies(
        at revision: Revision,
        version: Version? = nil,
        productFilter: ProductFilter
    ) throws -> (Manifest, [RepositoryPackageConstraint]) {
        let manifest = try loadManifest(at: revision, version: version)
        return (manifest, manifest.dependencyConstraints(productFilter: productFilter, mirrors: mirrors))
    }

    public override func getUnversionedDependencies(productFilter: ProductFilter) throws -> [PackageContainerConstraint] {
        // We just return an empty array if requested for unversioned dependencies.
        return []
    }

    public override func getUpdatedIdentifier(at boundVersion: BoundVersion) throws -> Identifier {
        let revision: Revision
        var version: Version?
        switch boundVersion {
        case .version(let v):
            let tag = knownVersions[v]!
            version = v
            revision = try self.getRevision(forTag: tag)
        case .revision(let identifier):
            revision = try self.getRevision(forIdentifier: identifier)
        case .unversioned, .excluded:
            assertionFailure("Unexpected type requirement \(boundVersion)")
            return self.identifier
        }

        let manifest = try loadManifest(at: revision, version: version)
        return self.identifier.with(newName: manifest.name)
    }

    /// Returns true if the tools version is valid and can be used by this
    /// version of the package manager.
    private func isValidToolsVersion(_ toolsVersion: ToolsVersion) -> Bool {
        do {
            try toolsVersion.validateToolsVersion(currentToolsVersion, packagePath: "")
            return true
        } catch {
            return false
        }
    }

    public override func isToolsVersionCompatible(at version: Version) -> Bool {
        return (try? self.toolsVersion(for: version)).flatMap(self.isValidToolsVersion(_:)) ?? false
    }

    private func loadManifest(at revision: Revision, version: Version?) throws -> Manifest {
        return try self.manifestCache.memo(key: revision, lock: self.manifestCacheLock) {
            let fs = try repository.openFileView(revision: revision)
            let packageURL = identifier.repository.url

            // Load the tools version.
            let toolsVersion = try toolsVersionLoader.load(at: .root, fileSystem: fs)

            // Validate the tools version.
            try toolsVersion.validateToolsVersion(
                self.currentToolsVersion, version: revision.identifier, packagePath: packageURL)

            // Load the manifest.
            return try manifestLoader.load(
                package: AbsolutePath.root,
                baseURL: packageURL,
                version: version,
                toolsVersion: toolsVersion,
                packageKind: identifier.kind,
                fileSystem: fs)
        }
    }
}

/// Adaptor for exposing repositories as PackageContainerProvider instances.
///
/// This is the root class for bridging the manifest & SCM systems into the
/// interfaces used by the `DependencyResolver` algorithm.
public class RepositoryPackageContainerProvider: PackageContainerProvider {
    let repositoryManager: RepositoryManager
    let manifestLoader: ManifestLoaderProtocol
    let mirrors: DependencyMirrors

    /// The tools version currently in use. Only the container versions less than and equal to this will be provided by
    /// the container.
    let currentToolsVersion: ToolsVersion

    /// The tools version loader.
    let toolsVersionLoader: ToolsVersionLoaderProtocol

    /// Queue for callbacks.
    //private let callbacksQueue = DispatchQueue(label: "org.swift.swiftpm.container-provider")

    /// Create a repository-based package provider.
    ///
    /// - Parameters:
    ///   - repositoryManager: The repository manager responsible for providing repositories.
    ///   - manifestLoader: The manifest loader instance.
    ///   - currentToolsVersion: The current tools version in use.
    ///   - toolsVersionLoader: The tools version loader.
    public init(
        repositoryManager: RepositoryManager,
        mirrors: DependencyMirrors = [:],
        manifestLoader: ManifestLoaderProtocol,
        currentToolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        toolsVersionLoader: ToolsVersionLoaderProtocol = ToolsVersionLoader()
    ) {
        self.repositoryManager = repositoryManager
        self.mirrors = mirrors
        self.manifestLoader = manifestLoader
        self.currentToolsVersion = currentToolsVersion
        self.toolsVersionLoader = toolsVersionLoader
    }

    public func getContainer(
        for identifier: PackageReference,
        skipUpdate: Bool,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PackageContainer, Swift.Error>) -> Void
    ) {
        // If the container is local, just create and return a local package container.
        if identifier.kind != .remote {
            callbackQueue.async {
                let container = LocalPackageContainer(identifier,
                    mirrors: self.mirrors,
                    manifestLoader: self.manifestLoader,
                    toolsVersionLoader: self.toolsVersionLoader,
                    currentToolsVersion: self.currentToolsVersion,
                    fs: self.repositoryManager.fileSystem)
                completion(.success(container))
            }
            return
        }

        // Resolve the container using the repository manager.
        repositoryManager.lookup(repository: identifier.repository, skipUpdate: skipUpdate, callbackQueue: callbackQueue) { result in
            // Create the container wrapper.
            let container = result.tryMap { handle -> PackageContainer in
                // Open the repository.
                //
                // FIXME: Do we care about holding this open for the lifetime of the container.
                let repository = try handle.open()
                return RepositoryPackageContainer(
                    identifier: identifier,
                    mirrors: self.mirrors,
                    repository: repository,
                    manifestLoader: self.manifestLoader,
                    toolsVersionLoader: self.toolsVersionLoader,
                    currentToolsVersion: self.currentToolsVersion
                )
            }
            completion(container)
        }
    }
    
    
}
