/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import TSCUtility
import SourceControl
import Dispatch
import class Foundation.NSUUID

/// The error encountered during in memory git repository operations.
public enum InMemoryGitRepositoryError: Swift.Error {
    case unknownRevision
    case unknownTag
    case tagAlreadyPresent
}

// FIXME TOMER: add delay
/// A class that implements basic git features on in-memory file system. It takes the path and file system reference
/// where the repository should be created. The class itself is a file system pointing to current revision state
/// i.e. HEAD. All mutations should be made on file system interface of this class and then they can be committed using
/// commit() method. Calls to checkout related methods will checkout the HEAD on the passed file system at the
/// repository path, as well as on the file system interface of this class.
/// Note: This class is intended to be used as testing infrastructure only.
/// Note: This class is not thread safe yet.
public final class InMemoryGitRepository {
    /// The revision identifier.
    public typealias RevisionIdentifier = String

    /// A struct representing a revision state. Minimally it contains a hash identifier for the revision
    /// and the file system state.
    fileprivate struct RevisionState {
        /// The revision identifier hash. It should be unique amoung all the identifiers.
        var hash: RevisionIdentifier

        /// The filesystem state contained in this revision.
        let fileSystem: InMemoryFileSystem

        /// Creates copy of the state.
        func copy() -> RevisionState {
            return RevisionState(hash: hash, fileSystem: fileSystem.copy())
        }
    }

    /// THe HEAD i.e. the current checked out state.
    fileprivate var head: RevisionState

    /// The history dictionary.
    fileprivate var history: [RevisionIdentifier: RevisionState] = [:]

    /// The map containing tag name to revision identifier values.
    fileprivate var tagsMap: [String: RevisionIdentifier] = [:]

    /// The array of current tags in the repository.
    public func tags(completion: @escaping (Result<[String], Error>) -> Void) {
        return completion(.success(Array(tagsMap.keys)))
    }

    /// The list of revisions in the repository.
    public var revisions: [RevisionIdentifier] {
        return Array(history.keys)
    }

    /// Indicates whether there are any uncommited changes in the repository.
    fileprivate var isDirty = false

    /// The path at which this repository is located.
    fileprivate let path: AbsolutePath

    /// The file system in which this repository should be installed.
    private let fs: InMemoryFileSystem

    /// Create a new repository at the given path and filesystem.
    public init(path: AbsolutePath, fs: InMemoryFileSystem) {
        self.path = path
        self.fs = fs
        // Point head to a new revision state with empty hash to begin with.
        head = RevisionState(hash: "", fileSystem: InMemoryFileSystem())
    }

    /// Copy/clone this repository.
    fileprivate func copy(at newPath: AbsolutePath? = nil) -> InMemoryGitRepository {
        let path = newPath ?? self.path
        try! fs.createDirectory(path, recursive: true)
        let repo = InMemoryGitRepository(path: path, fs: fs)
        for (revision, state) in history {
            repo.history[revision] = state.copy()
        }
        repo.tagsMap = tagsMap
        repo.head = head.copy()
        return repo
    }

    /// Commits the current state of the repository filesystem and returns the commit identifier.
    @discardableResult
    public func commit() -> String {
        // Create a fake hash for thie commit.
        let hash = String((NSUUID().uuidString + NSUUID().uuidString).prefix(40))
        head.hash = hash
        // Store the commit in history.
        history[hash] = head.copy()
        // We are not dirty anymore.
        isDirty = false
        // Install the current HEAD i.e. this commit to the filesystem that was passed.
        try! installHead()
        return hash
    }

    /// Checks out the provided revision.
    public func checkout(revision: RevisionIdentifier) throws {
        guard let state = history[revision] else {
            throw InMemoryGitRepositoryError.unknownRevision
        }
        // Point the head to the revision state.
        head = state
        isDirty = false
        // Install this state on the passed filesystem.
        try installHead()
    }

    /// Checks out a given tag.
    // FIXME: TOMER thread safety
    public func checkout(tag: String, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard let hash = tagsMap[tag] else {
                throw InMemoryGitRepositoryError.unknownTag
            }
            // Point the head to the revision state of the tag.
            // It should be impossible that a tag exisits which doesnot have a state.
            head = history[hash]!
            isDirty = false
            // Install this state on the passed filesystem.
            try installHead()
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
        
    }

    /// Installs (or checks out) current head on the filesystem on which this repository exists.
    fileprivate func installHead() throws {
        // Remove the old state.
        try fs.removeFileTree(path)
        // Create the repository directory.
        try fs.createDirectory(path, recursive: true)
        // Get the file system state at the HEAD,
        let headFs = head.fileSystem

        /// Recursively copies the content at HEAD to fs.
        func install(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
            assert(headFs.isDirectory(sourcePath))
            for entry in try headFs.getDirectoryContents(sourcePath) {
                // The full path of the entry.
                let sourceEntryPath = sourcePath.appending(component: entry)
                let destinationEntryPath = destinationPath.appending(component: entry)
                if headFs.isFile(sourceEntryPath) {
                    // If we have a file just write the file.
                    let bytes = try headFs.readFileContents(sourceEntryPath)
                    try fs.writeFileContents(destinationEntryPath, bytes: bytes)
                } else if headFs.isDirectory(sourceEntryPath) {
                    // If we have a directory, create that directory and copy its contents.
                    try fs.createDirectory(destinationEntryPath, recursive: false)
                    try install(from: sourceEntryPath, to: destinationEntryPath)
                }
            }
        }
        // Install at the repository path.
        try install(from: .root, to: path)
    }

    /// Tag the current HEAD with the given name.
    public func tag(name: String) throws {
        guard tagsMap[name] == nil else {
            throw InMemoryGitRepositoryError.tagAlreadyPresent
        }
        tagsMap[name] = head.hash
    }

    public func hasUncommittedChanges(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(isDirty))
    }

    public func fetch(completion: @escaping (Result<Void, Error>) -> Void) {
        // TODO.
        completion(.success(()))
    }
}

extension InMemoryGitRepository: FileSystem {

    public func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
        return head.fileSystem.exists(path, followSymlink: followSymlink)
    }

    public func isDirectory(_ path: AbsolutePath) -> Bool {
        return head.fileSystem.isDirectory(path)
    }

    public func isFile(_ path: AbsolutePath) -> Bool {
        return head.fileSystem.isFile(path)
    }

    public func isSymlink(_ path: AbsolutePath) -> Bool {
        return head.fileSystem.isSymlink(path)
    }

    public func isExecutableFile(_ path: AbsolutePath) -> Bool {
        return head.fileSystem.isExecutableFile(path)
    }

    public var currentWorkingDirectory: AbsolutePath? {
        return AbsolutePath("/")
    }

    public func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
        throw FileSystemError(.unsupported, path)
    }

    public var homeDirectory: AbsolutePath {
        fatalError("Unsupported")
    }

    public var cachesDirectory: AbsolutePath? {
        fatalError("Unsupported")
    }

    public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        return try head.fileSystem.getDirectoryContents(path)
    }

    public func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        try head.fileSystem.createDirectory(path, recursive: recursive)
    }
    
    public func createSymbolicLink(_ path: AbsolutePath, pointingAt destination: AbsolutePath, relative: Bool) throws {
        throw FileSystemError(.unsupported, path)
    }

    public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        return try head.fileSystem.readFileContents(path)
    }

    public func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        try head.fileSystem.writeFileContents(path, bytes: bytes)
        isDirty = true
    }

    public func removeFileTree(_ path: AbsolutePath) throws {
        try head.fileSystem.removeFileTree(path)
    }

    public func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
        try head.fileSystem.chmod(mode, path: path, options: options)
    }

    public func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        try head.fileSystem.copy(from: sourcePath, to: destinationPath)
    }

    public func move(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        try head.fileSystem.move(from: sourcePath, to: destinationPath)
    }
}

extension InMemoryGitRepository: Repository {
    public func resolveRevision(tag: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        return completion(.success(Revision(identifier: tagsMap[tag]!)))
    }

    public func resolveRevision(identifier: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        return completion(.success(Revision(identifier: tagsMap[identifier] ?? identifier)))
    }

    public func exists(revision: Revision, completion: @escaping (Result<Bool, Error>) -> Void) {
        return completion(.success(history[revision.identifier] != nil))
    }

    public func openFileView(revision: Revision, completion: @escaping (Result<FileSystem, Error>) -> Void) {
        return completion(.success(history[revision.identifier]!.fileSystem))
    }
}

// FIXME TOMER: add delay
extension InMemoryGitRepository: WorkingCheckout {
    public func getCurrentRevision(completion: @escaping (Result<Revision, Error>) -> Void) {
        completion(.success(Revision(identifier: head.hash)))
    }

    public func checkout(revision: Revision, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            completion(.success(try checkout(revision: revision.identifier)))
        } catch {
            completion(.failure(error))
        }
    }

    public func hasUnpushedCommits(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    public func checkout(newBranch: String, completion: @escaping (Result<Void, Error>) -> Void) {
        history[newBranch] = head
        completion(.success(()))
    }

    public func isAlternateObjectStoreValid(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    public func areIgnored(_ paths: [AbsolutePath], completion: @escaping (Result<[Bool], Error>) -> Void) {
        completion(.success([false]))
    }
}

/// This class implement provider for in memeory git repository.
// FIXME: TOMer make thread-safe
public final class InMemoryGitRepositoryProvider: RepositoryProvider {
    /// Contains the repository added to this provider.
    public private(set) var specifierMap = [RepositorySpecifier: InMemoryGitRepository]()

    /// Contains the repositories which are fetched using this provider.
    private var fetchedMap = [AbsolutePath: InMemoryGitRepository]()

    /// Contains the repositories which are checked out using this provider.
    private var checkoutsMap = [AbsolutePath: InMemoryGitRepository]()

    /// Create a new provider.
    public init() {
    }

    /// Add a repository to this provider. Only the repositories added with this interface can be operated on
    /// with this provider.
    public func add(specifier: RepositorySpecifier, repository: InMemoryGitRepository) {
        // Save the repository in specifer map.
        specifierMap[specifier] = repository
    }

    /// This method returns the stored reference to the git repository which was fetched or checked out.
    public func openRepo(at path: AbsolutePath) -> InMemoryGitRepository {
        return fetchedMap[path] ?? checkoutsMap[path]!
    }

    // MARK: - RepositoryProvider conformance
    // Note: These methods use force unwrap (instead of throwing) to honor their preconditions.

    public func fetch(repository: RepositorySpecifier, to path: AbsolutePath, completion: @escaping (Result<Void, Error>) -> Void) {
        let repo = specifierMap[RepositorySpecifier(url: repository.url.spm_dropGitSuffix())]!
        fetchedMap[path] = repo.copy()
        add(specifier: RepositorySpecifier(url: path.asURL.absoluteString), repository: repo)
        completion(.success(()))
    }

    public func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath, completion: @escaping (Result<Void, Error>) -> Void) {
        let repo = fetchedMap[sourcePath]!
        fetchedMap[destinationPath] = repo.copy()
        completion(.success(()))
    }

    public func open(repository: RepositorySpecifier, at path: AbsolutePath, completion: @escaping (Result<Repository, Error>) -> Void) {
        completion(.success(fetchedMap[path]!))
    }

    public func cloneCheckout(
        repository: RepositorySpecifier,
        at sourcePath: AbsolutePath,
        to destinationPath: AbsolutePath,
        editable: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let checkout = fetchedMap[sourcePath]!.copy(at: destinationPath)
        checkoutsMap[destinationPath] = checkout
        completion(.success(()))
    }

    public func checkoutExists(at path: AbsolutePath, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(checkoutsMap.keys.contains(path)))
    }

    public func openCheckout(at path: AbsolutePath, completion: @escaping (Result<WorkingCheckout, Error>) -> Void) {
        completion(.success(checkoutsMap[path]!))
    }
}

// FIXME: TOMER move somewhere else?
public extension GitRepository {
    func remotes() throws -> [(name: String, url: String)] {
        try tsc_await { self.remotes(completion: $0) }
    }

    func resolveHash(treeish: String, type: String? = nil) throws -> Hash {
        try tsc_await { self.resolveHash(treeish: treeish, type: type, completion: $0) }
    }

    func read(tree hash: Hash) throws -> Tree {
        try tsc_await { self.read(tree: hash, completion: $0) }
    }

    func read(commit hash: Hash) throws -> Commit {
        try tsc_await { self.read(commit: hash, completion: $0) }
    }

    func setURL(remote: String, url: String) throws {
        try tsc_await { self.setURL(remote: remote, url: url, completion: $0) }
    }
}

// FIXME: TOMER move somewhere else?
public extension Repository {
    func tags() throws -> [String] {
        try tsc_await { self.tags(completion: $0) }
    }

    func resolveRevision(tag: String) throws -> Revision {
        try tsc_await { self.resolveRevision(tag: tag, completion: $0) }
    }

    func resolveRevision(identifier: String) throws -> Revision {
        try tsc_await { self.resolveRevision(identifier: identifier, completion: $0) }
    }

    func fetch() throws {
        try tsc_await { self.fetch(completion: $0) }
    }

    func exists(revision: Revision) throws -> Bool {
        try tsc_await { self.exists(revision: revision, completion: $0) }
    }

    func openFileView(revision: Revision) throws -> FileSystem {
        try tsc_await { self.openFileView(revision: revision, completion: $0) }
    }
}

// FIXME: TOMER move somewhere else?
public extension WorkingCheckout {
    func getCurrentRevision() throws -> Revision {
        try tsc_await { self.getCurrentRevision(completion: $0) }
    }

    func hasUnpushedCommits() throws -> Bool {
        try tsc_await { self.hasUnpushedCommits(completion: $0) }
    }

    func hasUncommittedChanges() throws -> Bool {
        try tsc_await { self.hasUncommittedChanges(completion: $0) }
    }

    func checkout(tag: String) throws {
        try tsc_await { self.checkout(tag: tag, completion: $0) }
    }

    func checkout(revision: Revision) throws {
        try tsc_await { self.checkout(revision: revision, completion: $0) }
    }

    func checkout(newBranch: String) throws {
        try tsc_await { self.checkout(newBranch: newBranch, completion: $0) }
    }

    func isAlternateObjectStoreValid() throws -> Bool {
        try tsc_await { self.isAlternateObjectStoreValid(completion: $0) }
    }

    func areIgnored(_ paths: [AbsolutePath]) throws -> [Bool] {
        try tsc_await { self.areIgnored(paths, completion: $0) }
    }

    func tags2() throws -> [String] {
        try tsc_await { self.tags(completion: $0) }
    }

    func fetch2() throws {
        try tsc_await { self.fetch(completion: $0) }
    }

    func exists2(revision: Revision) throws -> Bool {
        try tsc_await { self.exists(revision: revision, completion: $0) }
    }
}


// FIXME: TOMER move somewhere else?
public extension RepositoryProvider {
    func fetch(repository: RepositorySpecifier, to path: AbsolutePath) throws {
        try tsc_await { self.fetch(repository: repository, to: path, completion: $0) }
    }

    func open(repository: RepositorySpecifier, at path: AbsolutePath) throws -> Repository {
        return try tsc_await { self.open(repository: repository, at: path, completion: $0) }
    }
    
    func cloneCheckout(repository: RepositorySpecifier, at sourcePath: AbsolutePath, to destinationPath: AbsolutePath, editable: Bool) throws {
        return try tsc_await { self.cloneCheckout(repository: repository, at: sourcePath, to: destinationPath, editable: editable, completion: $0) }
    }

    func checkoutExists(at path: AbsolutePath) throws -> Bool {
        return try tsc_await { self.checkoutExists(at: path, completion: $0) }
    }

    func openCheckout(at path: AbsolutePath) throws -> WorkingCheckout {
        return try tsc_await { self.openCheckout(at: path, completion: $0) }
    }
}
