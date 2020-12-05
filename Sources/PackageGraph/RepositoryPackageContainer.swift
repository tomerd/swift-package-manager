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

enum RepositoryPackageResolutionError: Swift.Error {
    /// A requested repository could not be cloned.
    case unavailableRepository
}

public typealias RepositoryPackageConstraint = PackageContainerConstraint

/// Adaptor to expose an individual repository as a package container.
public class RepositoryPackageContainer: PackageContainer, CustomStringConvertible {

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
    public func versions(filter isIncluded: (Version) -> Bool, completion: @escaping (Result<AnySequence<Version>, Error>) -> Void) {
        // FIXME TOMER
        return completion(.success(AnySequence(_reversedVersions.filter(isIncluded).lazy.filter({ version in
            // If we have the result cached, return that.
            if let result = self.validToolsVersionsCache[version] {
                return result
            }

            // Otherwise, compute and cache the result.
            let isValid = (try? temp_await { self.toolsVersion(for: version, completion: $0) }).flatMap(self.isValidToolsVersion(_:)) ?? false
            self.validToolsVersionsCache[version] = isValid
            return isValid
        }))))
    }

    public var reversedVersions: [Version] { _reversedVersions }

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
    
    public var identifier: PackageReference
    private let mirrors: DependencyMirrors
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion
    
    init(
        identifier: PackageReference,
        mirrors: DependencyMirrors,
        repository: Repository,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion
    ) {
        self.identifier = identifier
        self.mirrors = mirrors
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
        
        self.repository = repository

        // Compute the map of known versions.
        //
        // FIXME: Move this utility to a more stable location.
        let knownVersionsWithDuplicates = Git.convertTagsToVersionMap((try? temp_await { repository.tags(completion: $0) }) ?? [])

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
    }

    public var description: String {
        return "RepositoryPackageContainer(\(identifier.repository.url.debugDescription))"
    }

    public var isRemoteContainer: Bool? {
        return true
    }

    public func getTag(for version: Version) -> String? {
        return knownVersions[version]
    }

    /// Returns revision for the given tag.
    public func getRevision(forTag tag: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        if let revision = (self.revisionsCacheLock.withLock { self.revisionsCache[tag] }) {
            return completion(.success(revision))
        }
        repository.resolveRevision(tag: tag) { result in
            if case .success(let revision) = result {
                self.revisionsCacheLock.withLock {
                    self.revisionsCache[tag] = revision
                }
            }
            completion(result)
        }
    }

    /// Returns revision for the given identifier.
    public func getRevision(forIdentifier identifier: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        if let revision = (self.revisionsCacheLock.withLock { self.revisionsCache[identifier] }) {
            return completion(.success(revision))
        }
        repository.resolveRevision(identifier: identifier) { result in
            if case .success(let revision) = result {
                self.revisionsCacheLock.withLock {
                    self.revisionsCache[identifier] = revision
                }
            }
            completion(result)
        }
    }

    /// Returns the tools version of the given version of the package.
    public func toolsVersion(for version: Version, completion: @escaping (Result<ToolsVersion, Error>) -> Void) {
        if let toolsVersion = (self.toolsVersionCacheLock.withLock { self.toolsVersionCache[version] }) {
            return completion(.success(toolsVersion))
        }
        guard let tag = knownVersions[version] else {
            return completion(.failure(StringError("unknown tag \(version)")))
        }
        self.getRevision(forTag: tag) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let revision):
                self.repository.openFileView(revision: revision) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let fs):
                        do {
                            let toolsVersion = try self.toolsVersionLoader.load(at: .root, fileSystem: fs)
                            self.toolsVersionCacheLock.withLock {
                                self.toolsVersionCache[version] = toolsVersion
                            }
                            completion(.success(toolsVersion))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        guard let tag = knownVersions[version] else {
            return completion(.failure(StringError("unknown tag \(version)")))
        }
        
        self.getAndCacheDependencies(forIdentifier: tag, productFilter: productFilter,
            getDependencies: { completion in
                self.getRevision(forTag: tag) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let revision):
                        self._getDependencies(at: revision, version: version, productFilter: productFilter, completion: completion)
                    }
                }
            },
            completion: { result in
                let result = result.mapError { error -> Error in
                    GetDependenciesError(containerIdentifier: self.identifier.repository.url, reference: version.description, underlyingError: error, suggestion: nil)
                }
                completion(result.map{ $0.1 })
            })
        
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        self.getAndCacheDependencies(forIdentifier: revision, productFilter: productFilter,
            getDependencies: { completion in
                self.getRevision(forIdentifier: revision) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let revision):
                        self._getDependencies(at: revision, productFilter: productFilter, completion: completion)
                    }
                }
            },
            completion: { result in
                let result = result.mapError { error -> Error in
                    do {
                        // Examine the error to see if we can come up with a more informative and actionable error message.  We know that the revision is expected to be a branch name or a hash (tags are handled through a different code path).
                        if let error = error as? GitRepositoryError, error.description.contains("Needed a single revision") {
                            // It was a Git process invocation error.  Take a look at the repository to see if we can come up with a reasonable diagnostic.
                            if let rev = (try? temp_await { self.getRevision(forIdentifier: revision, completion: $0) }), (try temp_await { self.repository.exists(revision: rev, completion: $0) }) {
                                // Revision does exist, so something else must be wrong.
                                throw GetDependenciesError(
                                    containerIdentifier: self.identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
                            }
                            else {
                                // Revision does not exist, so we customize the error.
                                let sha1RegEx = try! RegEx(pattern: #"\A[:xdigit:]{40}\Z"#)
                                let isBranchRev = sha1RegEx.matchGroups(in: revision).compactMap{ $0 }.isEmpty
                                let errorMessage = "could not find " + (isBranchRev ? "a branch named ‘\(revision)’" : "the commit \(revision)")
                                let mainBranchExists = (try? temp_await { self.getRevision(forIdentifier: "main", completion: $0) }) != nil
                                let suggestion = (revision == "master" && mainBranchExists) ? "did you mean ‘main’?" : nil
                                throw GetDependenciesError(
                                    containerIdentifier: self.identifier.repository.url, reference: revision,
                                    underlyingError: StringError(errorMessage), suggestion: suggestion)
                            }
                        } else {
                            // If we get this far without having thrown an error, we wrap and throw the underlying error.
                            throw GetDependenciesError(
                                containerIdentifier: self.identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
                        }
                    } catch {
                        return error
                    }
                }
                completion(result.map{ $0.1 })
            })
    }

    private func getAndCacheDependencies(
        forIdentifier identifier: String,
        productFilter: ProductFilter,
        getDependencies: @escaping ( @escaping (Result<(Manifest, [RepositoryPackageConstraint]), Error>) -> Void) -> Void,
        completion: @escaping (Result<(Manifest, [RepositoryPackageConstraint]), Error>) -> Void
    ) {
        if let cached = (self.dependenciesCacheLock.withLock { self.dependenciesCache[identifier, default: [:]][productFilter] }) {
            return completion(.success(cached))
        }
        getDependencies() { result in
            if case .success(let deps) = result {
                self.dependenciesCacheLock.withLock {
                    self.dependenciesCache[identifier, default: [:]][productFilter] = deps
                }
            }
            completion(result)
        }
    }

    /// Returns dependencies of a container at the given revision.
    private func _getDependencies(
        at revision: Revision,
        version: Version? = nil,
        productFilter: ProductFilter,
        completion: @escaping (Result<(Manifest, [RepositoryPackageConstraint]), Error>) -> Void
    ) {
        self.loadManifest(at: revision, version: version) { result in
            completion(result.map { ($0, $0.dependencyConstraints(productFilter: productFilter, mirrors: self.mirrors)) })
        }
    }

    public func getUnversionedDependencies(productFilter: ProductFilter, completion: @escaping (Result<[PackageContainerConstraint], Error>) -> Void) {
        // We just return an empty array if requested for unversioned dependencies.
        return completion(.success([]))
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion, completion: @escaping (Result<PackageReference, Error>) -> Void) {
        switch boundVersion {
        case .version(let version):
            guard let tag = knownVersions[version] else {
                return completion(.failure(StringError("unknown tag \(version)")))
            }
            self.getRevision(forTag: tag) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let revision):
                    self.loadManifest(at: revision, version: version) { result in
                        completion(result.map{ self.identifier.with(newName: $0.name) })
                    }
                }
            }
        case .revision(let identifier):
            self.getRevision(forIdentifier: identifier) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let revision):
                    self.loadManifest(at: revision, version: nil) { result in
                        completion(result.map{ self.identifier.with(newName: $0.name) })
                    }
                }
            }
        case .unversioned, .excluded:
            assertionFailure("Unexpected type requirement \(boundVersion)")
            return completion(.success(self.identifier))
        }
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

    public func isToolsVersionCompatible(at version: Version, completion: @escaping (Result<Bool, Error>) -> Void) {
        self.toolsVersion(for: version) { result in
            completion(result.map { self.isValidToolsVersion($0) })
        }
    }

    private func loadManifest(at revision: Revision, version: Version?, completion: @escaping (Result<Manifest, Error>) -> Void) {
        if let manifest = (self.manifestCacheLock.withLock { self.manifestCache[revision] }) {
            return completion(.success(manifest))
        }
        
        repository.openFileView(revision: revision) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let fs):
                do {
                    let packageURL = self.identifier.repository.url

                    // Load the tools version.
                    let toolsVersion = try self.toolsVersionLoader.load(at: .root, fileSystem: fs)
                    // Validate the tools version.
                    try toolsVersion.validateToolsVersion(
                        self.currentToolsVersion, version: revision.identifier, packagePath: packageURL)

                    // Load the manifest.
                    self.manifestLoader.load(
                        package: AbsolutePath.root,
                        baseURL: packageURL,
                        version: version,
                        toolsVersion: toolsVersion,
                        packageKind: self.identifier.kind,
                        fileSystem: fs) { result in
                        if case .success(let manifest) = result {
                            self.manifestCacheLock.withLock {
                                self.manifestCache[revision] = manifest
                            }
                        }
                        completion(result)
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
        
        /*
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
        }*/
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
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let handle):
                // Open the repository.
                //
                // FIXME: Do we care about holding this open for the lifetime of the container.
                handle.open { result in
                    completion(result.map {
                        RepositoryPackageContainer(
                            identifier: identifier,
                            mirrors: self.mirrors,
                            repository: $0,
                            manifestLoader: self.manifestLoader,
                            toolsVersionLoader: self.toolsVersionLoader,
                            currentToolsVersion: self.currentToolsVersion)
                    })
                }
            }
        }
    }
}
