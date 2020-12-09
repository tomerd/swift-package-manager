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

/// Adaptor to expose an individual repository as a package container.
public class RepositoryPackageContainer: PackageContainer, CustomStringConvertible {
    public typealias Constraint = PackageContainerConstraint

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

    public let identifier: PackageReference
    private let repository: Repository
    private let mirrors: DependencyMirrors
    private let manifestLoader: ManifestLoaderProtocol
    private let toolsVersionLoader: ToolsVersionLoaderProtocol
    private let currentToolsVersion: ToolsVersion

    /// The cached dependency information.
    private var dependenciesCache = [String: [ProductFilter: (Manifest, [Constraint])]] ()
    private var dependenciesCacheLock = Lock()

    private var knownVersionsCache = ThreadSafeBox<[Version: String]>()
    private var reversedVersionsCache = ThreadSafeBox<[Version]>()
    private var manifestsCache = ThreadSafeKeyValueStore<Revision, Manifest>()
    private var toolsVersionsCache = ThreadSafeKeyValueStore<Version, ToolsVersion>()

    /// This is used to remember if tools version of a particular version is
    /// valid or not.
    internal var validToolsVersionsCache = ThreadSafeKeyValueStore<Version, Bool>()
    
    private let queue: DispatchQueue

    init(
        identifier: PackageReference,
        queue: DispatchQueue,
        mirrors: DependencyMirrors,
        repository: Repository,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersionLoader: ToolsVersionLoaderProtocol,
        currentToolsVersion: ToolsVersion
    ) {
        self.identifier = identifier
        self.queue = queue
        self.mirrors = mirrors
        self.repository = repository
        self.manifestLoader = manifestLoader
        self.toolsVersionLoader = toolsVersionLoader
        self.currentToolsVersion = currentToolsVersion
    }
    
    // Compute the map of known versions.
    private func knownVersions(completion: @escaping (Result<[Version: String], Error>) -> Void) {
        if let versions = self.knownVersionsCache.get() {
            return completion(.success(versions))
        }
        
        repository.tags() { result in
            let result = result.map { tags -> [Version: String] in
                let knownVersionsWithDuplicates = Git.convertTagsToVersionMap(tags)
                return knownVersionsWithDuplicates.mapValues({ tags -> String in
                    if tags.count == 2 {
                        // FIXME: Warn if the two tags point to different git references.
                        return tags.first(where: { !$0.hasPrefix("v") })!
                    }
                    assert(tags.count == 1, "Unexpected number of tags")
                    return tags[0]
                })
            }
            
            if case .success(let versions) = result {
                self.knownVersionsCache.put(versions)
            }
            
            completion(result)
        }
    }
    
    public func reversedVersions(completion: @escaping (Result<[Version], Error>) -> Void) {
        if let versions = self.reversedVersionsCache.get() {
            return completion(.success(versions))
        }
        
        self.knownVersions() { result in
            let result = result.map { Array(($0.keys.sorted().reversed())) }
            if case .success(let versions) = result {
                self.reversedVersionsCache.put(versions)
            }
            completion(result)
        }
    }
    
    /// The available version list (in reverse order).
    public func versions(filter isIncluded: @escaping (Version) -> Bool, completion: @escaping (Result<AnySequence<Version>, Error>) -> Void) {
        self.reversedVersions() { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let reversedVersions):
                let seq = AnySequence(reversedVersions.filter(isIncluded).lazy.filter({ it in
                    // If we have the result cached, return that.
                    if let result = self.validToolsVersionsCache[it] {
                        return result
                    }

                    // Otherwise, compute and cache the result.
                    let isValid = (try? temp_await { self.toolsVersion(for: it, completion: $0) }).flatMap(self.isValidToolsVersion(_:)) ?? false
                    self.validToolsVersionsCache[it] = isValid
                    return isValid
                }))
                completion(.success(seq))
            }
        }
    }

    public func getTag(for version: Version, completion: @escaping (Result<String?, Error>) -> Void) {
        self.knownVersions() { result in
            switch result {
            case .failure(let error):
                completion(.failure(error)) // FIXME: TOMER return nil?
            case .success(let knownVersions):
                completion(.success(knownVersions[version]))
            }
        }
        //return try? self.knownVersions()[version]
    }

    /// Returns revision for the given tag.
    public func getRevision(forTag tag: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        repository.resolveRevision(tag: tag, completion: completion)
    }

    /// Returns revision for the given identifier.
    public func getRevision(forIdentifier identifier: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        repository.resolveRevision(identifier: identifier, completion: completion)
    }

    /// Returns the tools version of the given version of the package.
    public func toolsVersion(for version: Version, completion: @escaping (Result<ToolsVersion, Error>) -> Void) {
        if let toolsVersion = self.toolsVersionsCache[version] {
            return completion(.success(toolsVersion))
        }
        
        self.knownVersions() { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let knownVersions):
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
                                    self.toolsVersionsCache[version] = toolsVersion
                                    completion(.success(toolsVersion))
                                } catch {
                                    completion(.failure(error))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public func getDependencies(at version: Version, productFilter: ProductFilter, completion: @escaping (Result<[Constraint], Error>) -> Void) {
        self.getTag(for: version) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let tag):
                guard let tag = tag else {
                    return completion(.failure(StringError("unknown tag \(version)")))
                }
                self.getAndCacheDependencies(forIdentifier: tag, productFilter: productFilter,
                    getDependencies: { completion in
                        self.getRevision(forTag: tag) { result in
                            switch result {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let revision):
                                self.getDependencies(at: revision, version: version, productFilter: productFilter, completion: completion)
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
        }
        
        /*do {
            return try cachedDependencies(forIdentifier: version.description, productFilter: productFilter) {
                guard let tag = try self.knownVersions()[version] else {
                    throw StringError("unknown tag \(version)")
                }
                let revision = try repository.resolveRevision(tag: tag)
                return try getDependencies(at: revision, version: version, productFilter: productFilter)
            }.1
        } catch {
            throw GetDependenciesError(
                containerIdentifier: identifier.repository.url, reference: version.description, underlyingError: error, suggestion: nil)
        }*/
    }

    public func getDependencies(at revision: String, productFilter: ProductFilter, completion: @escaping (Result<[Constraint], Error>) -> Void) {
        self.getAndCacheDependencies(forIdentifier: revision, productFilter: productFilter,
            getDependencies: { completion in
                self.getRevision(forIdentifier: revision) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let revision):
                        self.getDependencies(at: revision, productFilter: productFilter, completion: completion)
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
    
        /*do {
            return try cachedDependencies(forIdentifier: revision, productFilter: productFilter) {
                // resolve the revision identifier and return its dependencies.
                let revision = try repository.resolveRevision(identifier: revision)
                return try getDependencies(at: revision, productFilter: productFilter)
            }.1
        } catch {
            // Examine the error to see if we can come up with a more informative and actionable error message.  We know that the revision is expected to be a branch name or a hash (tags are handled through a different code path).
            if let error = error as? GitRepositoryError, error.description.contains("Needed a single revision") {
                // It was a Git process invocation error.  Take a look at the repository to see if we can come up with a reasonable diagnostic.
                if let rev = try? repository.resolveRevision(identifier: revision), repository.exists(revision: rev) {
                    // Revision does exist, so something else must be wrong.
                    throw GetDependenciesError(
                        containerIdentifier: identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
                }
                else {
                    // Revision does not exist, so we customize the error.
                    let sha1RegEx = try! RegEx(pattern: #"\A[:xdigit:]{40}\Z"#)
                    let isBranchRev = sha1RegEx.matchGroups(in: revision).compactMap{ $0 }.isEmpty
                    let errorMessage = "could not find " + (isBranchRev ? "a branch named ‘\(revision)’" : "the commit \(revision)")
                    let mainBranchExists = (try? repository.resolveRevision(identifier: "main")) != nil
                    let suggestion = (revision == "master" && mainBranchExists) ? "did you mean ‘main’?" : nil
                    throw GetDependenciesError(
                        containerIdentifier: identifier.repository.url, reference: revision,
                        underlyingError: StringError(errorMessage), suggestion: suggestion)
                }
            }
            // If we get this far without having thrown an error, we wrap and throw the underlying error.
            throw GetDependenciesError(containerIdentifier: identifier.repository.url, reference: revision, underlyingError: error, suggestion: nil)
        }*/
    }
    
    private func getAndCacheDependencies(
            forIdentifier identifier: String,
            productFilter: ProductFilter,
            getDependencies: @escaping ( @escaping (Result<(Manifest, [Constraint]), Error>) -> Void) -> Void,
            completion: @escaping (Result<(Manifest, [Constraint]), Error>) -> Void
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

    /*private func cachedDependencies(
        forIdentifier identifier: String,
        productFilter: ProductFilter,
        getDependencies: () throws -> (Manifest, [Constraint])
    ) throws -> (Manifest, [Constraint]) {
        return try dependenciesCacheLock.withLock {
            if let result = dependenciesCache[identifier, default: [:]][productFilter] {
                return result
            }
            let result = try getDependencies()
            dependenciesCache[identifier, default: [:]][productFilter] = result
            return result
        }
    }*/

    /// Returns dependencies of a container at the given revision.
    private func getDependencies(
        at revision: Revision,
        version: Version? = nil,
        productFilter: ProductFilter,
        completion: @escaping (Result<(Manifest, [Constraint]), Error>) -> Void
    ) {
        self.loadManifest(at: revision, version: version) { result in
            completion(result.map { ($0, $0.dependencyConstraints(productFilter: productFilter, mirrors: self.mirrors)) })
        }
    }
    /*private func getDependencies(
        at revision: Revision,
        version: Version? = nil,
        productFilter: ProductFilter
    ) throws -> (Manifest, [Constraint]) {
        let manifest = try self.loadManifest(at: revision, version: version)
        return (manifest, manifest.dependencyConstraints(productFilter: productFilter, mirrors: mirrors))
    }*/

    public func getUnversionedDependencies(productFilter: ProductFilter, completion: @escaping (Result<[Constraint], Error>) -> Void) {
        // We just return an empty array if requested for unversioned dependencies.
        completion(.success([]))
    }

    public func getUpdatedIdentifier(at boundVersion: BoundVersion, completion: @escaping (Result<PackageReference, Error>) -> Void) {
        switch boundVersion {
        case .version(let version):
            self.getTag(for: version) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let tag):
                    guard let tag = tag else {
                        return completion(.failure(StringError("unknown tag \(version)")))
                    }
                    self.repository.resolveRevision(tag: tag) { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(error))
                        case .success(let revision):
                            self.loadManifest(at: revision, version: version) { result in
                                completion(result.map { self.identifier.with(newName: $0.name) })
                            }
                        }
                    }
                }
            }
        case .revision(let identifier):
            repository.resolveRevision(identifier: identifier) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let revision):
                    self.loadManifest(at: revision, version: nil) { result in
                        completion(result.map { self.identifier.with(newName: $0.name) })
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
            switch result {
            case .failure(let error):
                completion(.failure(error)) // FIXME: TOMER return false?
            case .success(let toolsVersion):
                completion(.success(self.isValidToolsVersion(toolsVersion)))
            }
        }
        //return (try? self.toolsVersion(for: version)).flatMap(self.isValidToolsVersion(_:)) ?? false
    }
   
    private func loadManifest(at revision: Revision, version: Version?, completion: @escaping (Result<Manifest, Error>) -> Void) {
        if let manifest = self.manifestsCache[revision] {
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
                    self.manifestLoader.load(package: AbsolutePath.root,
                                             baseURL: packageURL,
                                             version: version,
                                             toolsVersion: toolsVersion,
                                             packageKind: self.identifier.kind,
                                             fileSystem: fs,
                                             on: self.queue) { result in
                        if case .success(let manifest) = result {
                            self.manifestsCache[revision] = manifest
                        }
                        completion(result)
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
        
        
        /*try self.manifestsCache.memoize(revision) {
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

    public var isRemoteContainer: Bool? {
        return true
    }

    public var description: String {
        return "RepositoryPackageContainer(\(identifier.repository.url.debugDescription))"
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
        on queue: DispatchQueue,
        completion: @escaping (Result<PackageContainer, Swift.Error>) -> Void
    ) {
        // If the container is local, just create and return a local package container.
        if identifier.kind != .remote {
            queue.async {
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
        repositoryManager.lookup(repository: identifier.repository, skipUpdate: skipUpdate, on: queue) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let handle):
                // FIXME: Do we care about holding this open for the lifetime of the container.
                handle.open() { result in
                    let result = result.tryMap { repository -> PackageContainer in
                        return RepositoryPackageContainer(
                            identifier: identifier,
                            queue: queue,
                            mirrors: self.mirrors,
                            repository: repository,
                            manifestLoader: self.manifestLoader,
                            toolsVersionLoader: self.toolsVersionLoader,
                            currentToolsVersion: self.currentToolsVersion
                        )
                    }
                    completion(result)
                }
            }
        }
    }
}
