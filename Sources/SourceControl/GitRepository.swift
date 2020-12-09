/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import TSCBasic
import TSCUtility
import class Foundation.OperationQueue

// MARK: - GitShellHelper

/// Helper for shelling out to `git`
private struct GitShellHelper {
    /// Reference to process set, if installed.
    private let processSet: ProcessSet?
    
    private let operationQueue: OperationQueue
    
    init(processSet: ProcessSet? = nil) {
        self.processSet = processSet
        self.operationQueue = OperationQueue()
        self.operationQueue.name = "org.swift.swiftpm.git-shell"
        // FIXME: TOMER should compute off of CPU
        self.operationQueue.maxConcurrentOperationCount = 1
    }

    /// Private function to invoke the Git tool with its default environment and given set of arguments.  The specified
    /// failure message is used only in case of error.  This function waits for the invocation to finish and returns the
    /// output as a string.
    func run(_ args: [String],
             environment: [String: String] = Git.environment,
             on queue: DispatchQueue,
             barrier: Bool,
             completion: @escaping (Result<String, Error>) -> Void
    ) {
        //FIXME: TOMER double queue
        self.operationQueue.addOperation {
            //queue.async(flags: barrier ? .barrier : .assignCurrentContext) {
                let process = Process(arguments: [Git.tool] + args, environment: environment, outputRedirection: .collect)
                let result: ProcessResult
                do {
                    try self.processSet?.add(process)
                    try process.launch()
                    result = try process.waitUntilExit()
                    guard result.exitStatus == .terminated(code: 0) else {
                        return completion(.failure(GitShellError(result: result)))
                    }
                    return try completion(.success(result.utf8Output().spm_chomp()))
                } catch let error as GitShellError {
                    completion(.failure(error))
                } catch {
                    // Handle a failure to even launch the Git tool by synthesizing a result that we can wrap an error around.
                    let result = ProcessResult(arguments: process.arguments,
                                               environment: process.environment,
                                               exitStatus: .terminated(code: -1),
                                               output: .failure(error),
                                               stderrOutput: .failure(error))
                    completion(.failure(GitShellError(result: result)))
                }
            //}
        }
    }
}

// MARK: - GitRepositoryProvider

/// A `git` repository provider.
public struct GitRepositoryProvider: RepositoryProvider {
    private let git: GitShellHelper
    private let queue = DispatchQueue(label: "org.swift.swiftpm.git-provider", attributes: .concurrent)
    
    public init(processSet: ProcessSet? = nil) {
        self.git = GitShellHelper(processSet: processSet)
    }

    private func callGit(_ args: String...,
                         environment: [String: String] = Git.environment,
                         repository: RepositorySpecifier,
                         failureMessage: String = "",
                         completion: @escaping (Result<String, Error>) -> Void) {
        
        self.git.run(args, environment: environment, on: self.queue, barrier: false) { result in
            let result = result.mapError { error -> Error in
                if let error = error as? GitShellError {
                    return GitCloneError(repository: repository, message: failureMessage, result: error.result)
                } else {
                    return error
                }
            }
            completion(result)
        }
    }

    public func fetch(repository: RepositorySpecifier, to path: AbsolutePath, completion: @escaping (Result<Void, Error>) -> Void) {
        // Perform a bare clone.
        //
        // NOTE: We intentionally do not create a shallow clone here; the
        // expected cost of iterative updates on a full clone is less than on a
        // shallow clone.
        precondition(!localFileSystem.exists(path))
        // FIXME: Ideally we should pass `--progress` here and report status regularly.  We currently don't have callbacks for that.
        self.callGit("clone", "--mirror", repository.url, path.pathString,
                     repository: repository,
                     failureMessage: "Failed to clone repository \(repository.url)") { result in
            completion(result.map { _ in () })
        }
    }

    public func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath, completion: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            completion(Result(catching: { try localFileSystem.copy(from: sourcePath, to: destinationPath) }))
        }
    }

    public func open(repository: RepositorySpecifier, at path: AbsolutePath, completion: @escaping (Result<Repository, Error>) -> Void) {
        return completion(.success(GitRepository(path: path, isWorkingRepo: false)))
    }

    public func cloneCheckout(
        repository: RepositorySpecifier,
        at sourcePath: AbsolutePath,
        to destinationPath: AbsolutePath,
        editable: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if editable {
            // For editable clones, i.e. the user is expected to directly work on them, first we create
            // a clone from our cache of repositories and then we replace the remote to the one originally
            // present in the bare repository.
            self.callGit("clone", "--no-checkout", sourcePath.pathString, destinationPath.pathString,
                         repository: repository,
                         failureMessage: "Failed to clone repository \(repository.url)") { result in
                // The default name of the remote.
                let origin = "origin"
                // In destination repo remove the remote which will be pointing to the source repo.
                let clone = GitRepository(path: destinationPath)
                // Set the original remote to the new clone.
                clone.setURL(remote: origin, url: repository.url) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        // FIXME: This is unfortunate that we have to fetch to update remote's data.
                        clone.fetch(completion: completion)
                    }
                }
            }
        } else {
            // Clone using a shared object store with the canonical copy.
            //
            // We currently expect using shared storage here to be safe because we
            // only ever expect to attempt to use the working copy to materialize a
            // revision we selected in response to dependency resolution, and if we
            // re-resolve such that the objects in this repository changed, we would
            // only ever expect to get back a revision that remains present in the
            // object storage.
            self.callGit("clone", "--shared", "--no-checkout", sourcePath.pathString, destinationPath.pathString,
                             repository: repository,
                             failureMessage: "Failed to clone repository \(repository.url)") { result in
                completion(result.map { _ in () })
            }
        }
    }

    public func checkoutExists(at path: AbsolutePath, completion: @escaping (Result<Bool, Error>) -> Void) {
        precondition(localFileSystem.exists(path))

        let repo = GitRepository(path: path)
        repo.checkoutExists(completion: completion)
    }

    public func openCheckout(at path: AbsolutePath, completion: @escaping (Result<WorkingCheckout, Error>) -> Void) {
        completion(.success(GitRepository(path: path)))
    }
}

// MARK: - GitRepository

// FIXME: Currently, this class is serving two goals, it is the Repository
// interface used by `RepositoryProvider`, but is also a class which can be
// instantiated directly against non-RepositoryProvider controlled
// repositories. This may prove inconvenient if what is currently `Repository`
// becomes inconvenient or incompatible with the ideal interface for this
// class. It is possible we should rename `Repository` to something more
// abstract, and change the provider to just return an adaptor around this
// class.
//
/// A basic Git repository in the local file system (almost always a clone of a remote).  This class is thread safe.
public final class GitRepository: Repository, WorkingCheckout {
    /// A hash object.
    public struct Hash: Hashable {
        // FIXME: We should optimize this representation.
        let bytes: ByteString

        /// Create a hash from the given hexadecimal representation.
        ///
        /// - Returns; The hash, or nil if the identifier is invalid.
        public init?(_ identifier: String) {
            self.init(asciiBytes: ByteString(encodingAsUTF8: identifier).contents)
        }

        /// Create a hash from the given ASCII bytes.
        ///
        /// - Returns; The hash, or nil if the identifier is invalid.
        init?<C: Collection>(asciiBytes bytes: C) where C.Iterator.Element == UInt8 {
            if bytes.count != 40 {
                return nil
            }
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"),
                     UInt8(ascii: "a") ... UInt8(ascii: "z"):
                    continue
                default:
                    return nil
                }
            }
            self.bytes = ByteString(bytes)
        }
    }

    /// A commit object.
    public struct Commit: Equatable {
        /// The object hash.
        public let hash: Hash

        /// The tree contained in the commit.
        public let tree: Hash
    }

    /// A tree object.
    public struct Tree {
        public struct Entry {
            public enum EntryType {
                case blob
                case commit
                case executableBlob
                case symlink
                case tree

                init?(mode: Int) {
                    // Although the mode is a full UNIX mode mask, there are
                    // only a limited set of allowed values.
                    switch mode {
                    case 0o040000:
                        self = .tree
                    case 0o100644:
                        self = .blob
                    case 0o100755:
                        self = .executableBlob
                    case 0o120000:
                        self = .symlink
                    case 0o160000:
                        self = .commit
                    default:
                        return nil
                    }
                }
            }

            /// The hash of the object.
            public let hash: Hash

            /// The type of object referenced.
            public let type: EntryType

            /// The name of the object.
            public let name: String
        }

        /// The object hash.
        public let hash: Hash

        /// The list of contents.
        public let contents: [Entry]
    }

    /// The path of the repository in the local file system.
    public let path: AbsolutePath

    /// Concurrent queue to execute git cli on.
    private let git: GitShellHelper
    private let queue = DispatchQueue(label: "org.swift.swiftpm.git", attributes: .concurrent)

    /// If this repo is a work tree repo (checkout) as opposed to a bare repo.
    private let isWorkingRepo: Bool

    /// Dictionary for memoizing results of git calls that are not expected to change.
    private var cachedHashes = ThreadSafeKeyValueStore<String, Hash>()
    private var cachedBlobs = ThreadSafeKeyValueStore<Hash, ByteString>()
    private var cachedTrees = ThreadSafeKeyValueStore<Hash, Tree>()
    private var cachedTags = ThreadSafeBox<[String]>()

    public init(path: AbsolutePath, isWorkingRepo: Bool = true) {
        self.git = GitShellHelper()
        self.path = path
        self.isWorkingRepo = isWorkingRepo
        #if DEBUG
        self.isBare() { result in
            // Ignore if we couldn't run popen for some reason.
            if case .success(let isBare) = result {
                assert(isBare != isWorkingRepo)
            }
        }
        #endif
    }

    /// Private function to invoke the Git tool with its default environment and given set of arguments, specifying the
    /// path of the repository as the one to operate on.  The specified failure message is used only in case of error.
    /// This function waits for the invocation to finish and returns the output as a string.
    private func callGit(_ args: [String],
                         environment: [String: String] = Git.environment,
                         barrier: Bool,
                         failureMessage: String = "",
                         completion: @escaping (Result<String, Error>) -> Void) {
        
        self.git.run(["-C", self.path.pathString] + args, environment: environment, on: self.queue, barrier: barrier) { result in
            let result = result.mapError { error -> Error in
                if let error = error as? GitShellError {
                    return GitRepositoryError(path: self.path, message: failureMessage, result: error.result)
                } else {
                    return error
                }
            }
            completion(result)
        }
    }

    private func callGit(_ args: String...,
                         environment: [String: String] = Git.environment,
                         barrier: Bool,
                         failureMessage: String = "",
                         completion: @escaping (Result<String, Error>) -> Void) {
        self.callGit(args, environment: environment, barrier: barrier, failureMessage: failureMessage, completion: completion)
    }

    private func callGitVoid(_ args: String...,
                             environment: [String: String] = Git.environment,
                             barrier: Bool,
                             failureMessage: String = "",
                             completion: @escaping (Result<Void, Error>) -> Void) {
        self.callGit(args, environment: environment, barrier: barrier, failureMessage: failureMessage) { result in
            completion(result.map{ _ in () })
        }
    }

    /// Changes URL for the remote.
    ///
    /// - parameters:
    ///   - remote: The name of the remote to operate on. It should already be present.
    ///   - url: The new url of the remote.
    public func setURL(remote: String, url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // use barrier for write operations
        self.callGitVoid("remote", "set-url", remote, url,
                         barrier: true,
                         failureMessage: "Couldn’t set the URL of the remote ‘\(remote)’ to ‘\(url)’",
                         completion: completion)
    }

    /// Gets the current list of remotes of the repository.
    ///
    /// - Returns: An array of tuple containing name and url of the remote.
    // FIXME: TOMER: make pretty
    public func remotes(completion: @escaping (Result<[(name: String, url: String)], Error>) -> Void) {
        self.callGit("remote",
                     barrier: false,
                     failureMessage: "Couldn’t get the list of remotes") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let remoteNamesOutput):
                let remoteNames = remoteNamesOutput.split(separator: "\n").map(String.init)
                let sync = DispatchGroup()
                var results = [String: Result<String, Error>]()
                let lock = Lock()
                remoteNames.forEach { name in
                    sync.enter()
                    self.callGit("config", "--get", "remote.\(name).url",
                                 barrier: false,
                                 failureMessage: "Couldn’t get the URL of the remote ‘\(name)’") { result in
                        defer { sync.leave() }
                        lock.withLock {
                            results[name] = result
                        }
                    }
                }

                sync.wait()

                var errors = [Error]()
                var result = [(name: String, url: String)]()
                remoteNames.forEach { name in
                    switch results[name] {
                    case .success(let url):
                        result.append((name: name, url: url))
                    case .failure(let error):
                        errors.append(error)
                    default:
                        errors.append(StringError("unknown remote \(name)"))
                    }
                }

                // TODO: return all errors
                if let error = errors.first {
                    completion(.failure(error))
                } else {
                    completion(.success(result))
                }
            }
        }
    }

    // MARK: Repository Interface

    /// Returns the tags present in repository.
    public func tags(completion: @escaping (Result<[String], Error>) -> Void) {
        if let tags = cachedTags.get() {
            return completion(.success(tags))
        }
        
        self.callGit("tag", "-l",
                     barrier: false,
                     failureMessage: "Couldn’t get the list of tags") { result in
            let result = result.map{ $0.split(separator: "\n").map(String.init) }
            if case .success(let tags) = result {
                self.cachedTags.put(tags)
            }
            completion(result)
        }
    }

    public func resolveRevision(tag: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        self.resolveHash(treeish: tag, type: "commit") { result in
            completion(result.map{ Revision(identifier: $0.bytes.description) })
        }
    }

    public func resolveRevision(identifier: String, completion: @escaping (Result<Revision, Error>) -> Void) {
        self.resolveHash(treeish: identifier, type: "commit") { result in
            completion(result.map{ Revision(identifier: $0.bytes.description) })
        }
    }

    public func fetch(completion: @escaping (Result<Void, Error>) -> Void) {
        // use barrier for write operations
        self.callGitVoid("remote", "update", "-p",
                         barrier: true,
                         failureMessage: "Couldn’t fetch updates from remote repositories") { result in
            if case .success = result {
                self.cachedTags.clear()
            }
            completion(result)
        }
    }

    public func hasUncommittedChanges(completion: @escaping (Result<Bool, Error>) -> Void) {
        // Only a working repository can have changes.
        guard isWorkingRepo else {
            return completion(.success(false))
        }
        self.callGit("status", "-s", barrier: false) { result in
            completion(result.map { $0.isEmpty })
        }
    }

    public func openFileView(revision: Revision, completion: @escaping (Result<FileSystem, Error>) -> Void) {
        completion(.success(GitFileSystemView(repository: self, revision: revision)))
    }

    // MARK: Working Checkout Interface

    public func hasUnpushedCommits(completion: @escaping (Result<Bool, Error>) -> Void) {
        self.callGit("log", "--branches", "--not", "--remotes",
                     barrier: false,
                     failureMessage: "Couldn’t check for unpushed commits") { result in
            completion(result.map { !$0.isEmpty })
        }
    }

    public func getCurrentRevision(completion: @escaping (Result<Revision, Error>) -> Void) {
        self.callGit("rev-parse", "--verify", "HEAD",
                     barrier: false,
                     failureMessage: "Couldn’t get current revision") { result in
            completion(result.map { Revision(identifier: $0) })
        }
    }

    public func checkout(tag: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // FIXME: Audit behavior with off-branch tags in remote repositories, we
        // may need to take a little more care here.
        // use barrier for write operations
        self.callGitVoid("reset", "--hard", tag,
                         barrier: true,
                         failureMessage: "Couldn’t check out tag ‘\(tag)’") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.updateSubmoduleAndClean(completion: completion)
            }
        }
    }

    public func checkout(revision: Revision, completion: @escaping (Result<Void, Error>) -> Void) {
        // FIXME: Audit behavior with off-branch tags in remote repositories, we
        // may need to take a little more care here.
        // use barrier for write operations
        self.callGitVoid("checkout", "-f", revision.identifier,
                         barrier: true,
                         failureMessage: "Couldn’t check out revision ‘\(revision.identifier)’") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.updateSubmoduleAndClean(completion: completion)
            }
        }
    }

    internal func isBare(completion: @escaping (Result<Bool, Error>) -> Void) {
        self.callGit("rev-parse", "--is-bare-repository",
                     barrier: false,
                     failureMessage: "Couldn’t test for bare repository") { result in
            completion(result.map { $0 == "true" })
        }
    }

    internal func checkoutExists(completion: @escaping (Result<Bool, Error>) -> Void) {
        self.callGit("rev-parse", "--is-bare-repository",
                     barrier: false,
                     failureMessage: "Couldn’t test for bare repository") { result in
            switch result {
            case .failure:
               completion(.success(false))
            case .success(let output):
                completion(.success(output == "false"))
            }
            completion(result.map { $0 == "true" })
        }
    }

    /// Initializes and updates the submodules, if any, and cleans left over the files and directories using git-clean.
    private func updateSubmoduleAndClean(completion: @escaping (Result<Void, Error>) -> Void) {
        self.callGitVoid("submodule", "update", "--init", "--recursive",
                         barrier: false,
                         failureMessage: "Couldn’t update repository submodules") { result in
            switch result {
            case .failure(let error):
               completion(.failure(error))
            case .success:
                self.callGitVoid("clean", "-ffdx",
                                 barrier: false,
                                 failureMessage: "Couldn’t clean repository submodules",
                                 completion: completion)
            }
        }
    }

    /// Returns true if a revision exists.
    public func exists(revision: Revision, completion: @escaping (Result<Bool, Error>) -> Void) {
        self.callGit("rev-parse", "--verify", revision.identifier,
                     barrier: false) { result in
            switch result {
            case .failure:
                completion(.success(false))
            case .success:
                completion(.success(true))
            }
        }
    }

    public func checkout(newBranch: String, completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(self.isWorkingRepo, "This operation is only valid in a working repository")
        // use barrier for write operations
        self.callGitVoid("checkout", "-b", newBranch,
                         barrier: true,
                         failureMessage: "Couldn’t check out new branch ‘\(newBranch)’",
                         completion: completion)
    }

    /// Returns true if there is an alternative object store in the repository and it is valid.
    public func isAlternateObjectStoreValid(completion: @escaping (Result<Bool, Error>) -> Void) {
        self.queue.async {
            let objectStoreFile = self.path.appending(components: ".git", "objects", "info", "alternates")
            guard let bytes = try? localFileSystem.readFileContents(objectStoreFile) else {
                return completion(.success(false))
            }
            let split = bytes.contents.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false)
            guard let firstLine = ByteString(split[0]).validDescription else {
                return completion(.success(false))
            }
            completion(.success(localFileSystem.isDirectory(AbsolutePath(firstLine))))
        }
    }

    /// Returns true if the file at `path` is ignored by `git`
    public func areIgnored(_ paths: [AbsolutePath], completion: @escaping (Result<[Bool], Error>) -> Void) {
        self.queue.async {
            do {
                let stringPaths = paths.map { $0.pathString }

                try withTemporaryFile { pathsFile in
                    try localFileSystem.writeFileContents(pathsFile.path) {
                        for path in paths {
                            $0 <<< path.pathString <<< "\0"
                        }
                    }

                    let args = [
                        Git.tool, "-C", self.path.pathString.spm_shellEscaped(),
                        "check-ignore", "-z", "--stdin",
                        "<", pathsFile.path.pathString.spm_shellEscaped(),
                    ]
                    let argsWithSh = ["sh", "-c", args.joined(separator: " ")]
                    let result = try Process.popen(arguments: argsWithSh)
                    let output = try result.output.get()

                    let outputs: [String] = output.split(separator: 0).map { String(decoding: $0, as: Unicode.UTF8.self) }

                    guard result.exitStatus == .terminated(code: 0) || result.exitStatus == .terminated(code: 1) else {
                        throw GitInterfaceError.fatalError
                    }
                    completion(.success(stringPaths.map(outputs.contains)))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: Git Operations

    /// Resolve a "treeish" to a concrete hash.
    ///
    /// Technically this method can accept much more than a "treeish", it maps
    /// to the syntax accepted by `git rev-parse`.
    public func resolveHash(treeish: String, type: String? = nil, completion: @escaping (Result<Hash, Error>) -> Void) {
        let specifier: String
        if let type = type {
            specifier = treeish + "^{\(type)}"
        } else {
            specifier = treeish
        }
        
        if let hash = self.cachedHashes[specifier] {
            return completion(.success(hash))
        }
        
        self.callGit("rev-parse", "--verify", specifier,
                     barrier: false,
                     failureMessage: "Couldn’t get revision ‘\(specifier)’") { result in

            let result = result.flatMap { response -> Result<Hash, Error> in
                if let hash = Hash(response) {
                    return .success(hash)
                } else {
                    return .failure(GitInterfaceError.malformedResponse("expected an object hash in \(response)"))
                }
            }

            if case .success(let hash) = result {
                self.cachedHashes[specifier] = hash
            }

            completion(result)
        }
    }

    /// Read the commit referenced by `hash`.
    public func read(commit hash: Hash, completion: @escaping (Result<Commit, Error>) -> Void) {
        // Currently, we just load the tree, using the typed `rev-parse` syntax.
        self.resolveHash(treeish: hash.bytes.description, type: "tree") { result in
            completion(result.map{ Commit(hash: hash, tree: $0) })
        }
    }

    /// Read a tree object.
    public func read(tree hash: Hash, completion: @escaping (Result<Tree, Error>) -> Void) {
        if let treeInfo = self.cachedTrees[hash] {
            return completion(.success(treeInfo))
        }
    
        self.callGit("ls-tree", hash.bytes.description,
                     barrier: false,
                     failureMessage: "Couldn’t read ‘\(hash.bytes.description)’") { result in

            let result = result.flatMap { treeInfo -> Result<Tree, Error> in
                do {
                    var contents: [Tree.Entry] = []
                    for line in treeInfo.components(separatedBy: "\n") {
                        // Ignore empty lines.
                        if line == "" { continue }

                        // Each line in the response should match:
                        //
                        //   `mode type hash\tname`
                        //
                        // where `mode` is the 6-byte octal file mode, `type` is a 4-byte or 6-byte
                        // type ("blob", "tree", "commit"), `hash` is the hash, and the remainder of
                        // the line is the file name.
                        let bytes = ByteString(encodingAsUTF8: line)
                        let expectedBytesCount = 6 + 1 + 4 + 1 + 40 + 1
                        guard bytes.count > expectedBytesCount,
                              bytes.contents[6] == UInt8(ascii: " "),
                              // Search for the second space since `type` is of variable length.
                              let secondSpace = bytes.contents[6 + 1 ..< bytes.contents.endIndex].firstIndex(of: UInt8(ascii: " ")),
                              bytes.contents[secondSpace] == UInt8(ascii: " "),
                              bytes.contents[secondSpace + 1 + 40] == UInt8(ascii: "\t") else {
                            throw GitInterfaceError.malformedResponse("unexpected tree entry '\(line)' in '\(treeInfo)'")
                        }

                        // Compute the mode.
                        let mode = bytes.contents[0..<6].reduce(0) { (acc: Int, char: UInt8) in
                            (acc << 3) | (Int(char) - Int(UInt8(ascii: "0")))
                        }
                        guard let type = Tree.Entry.EntryType(mode: mode),
                              let hash = Hash(asciiBytes: bytes.contents[(secondSpace + 1)..<(secondSpace + 1 + 40)]),
                              let name = ByteString(bytes.contents[(secondSpace + 1 + 40 + 1)..<bytes.count]).validDescription else
                        {
                            throw GitInterfaceError.malformedResponse("unexpected tree entry '\(line)' in '\(treeInfo)'")
                        }

                        // FIXME: We do not handle de-quoting of names, currently.
                        if name.hasPrefix("\"") {
                            throw GitInterfaceError.malformedResponse("unexpected tree entry '\(line)' in '\(treeInfo)'")
                        }

                        contents.append(Tree.Entry(hash: hash, type: type, name: name))
                    }

                    return .success(Tree(hash: hash, contents: contents))
                } catch {
                    return .failure(error)
                }
            }

            if case .success(let treeInfo) = result {
                self.cachedTrees[hash] = treeInfo
            }

            completion(result)
        }
    }

    /// Read a blob object.
    func read(blob hash: Hash, completion: @escaping (Result<ByteString, Error>) -> Void) {
        if let blob = self.cachedBlobs[hash] {
           return completion(.success(blob))
       }

       self.callGit("cat-file", "-p", hash.bytes.description,
                    barrier: false,
                    failureMessage: "Couldn’t get blob ‘\(hash.bytes.description)’") { result in

           let result = result.map { ByteString(encodingAsUTF8: $0) }
           if case .success(let blob) = result {
               self.cachedBlobs[hash] = blob
           }
           completion(result)
       }
    }
}

// MARK: - GitFileSystemView

/// A `git` file system view.
///
/// The current implementation is based on lazily caching data with no eviction
/// policy, and is very unoptimized.
private final class GitFileSystemView: FileSystem {
    typealias Hash = GitRepository.Hash
    typealias Tree = GitRepository.Tree

    // MARK: Git Object Model

    // The map of loaded trees.
    var trees: [Hash: Tree] = [:]

    /// The underlying repository.
    let repository: GitRepository

    /// The revision this is a view on.
    let revision: Revision

    /// The root tree hash.
    let rootCache = ThreadSafeBox<GitRepository.Hash>()

    init(repository: GitRepository, revision: Revision) {
        self.repository = repository
        self.revision = revision
    }

    // MARK: FileSystem Implementation

    
    // FIXME: TOMER make async
    private func getEntry(_ path: AbsolutePath) throws -> Tree.Entry? {
        let root = try self.rootCache.memoize() {
            guard let hash = Hash(revision.identifier) else {
                throw StringError("invalid hash \(revision.identifier))")
            }
            return try temp_await { repository.read(commit: hash, completion: $0) }.tree
        }
        
        // Walk the components resolving the tree (starting with a synthetic
        // root entry).
        var current: Tree.Entry = Tree.Entry(hash: root, type: .tree, name: "/")
        var currentPath = AbsolutePath.root
        for component in path.components.dropFirst(1) {
            // Skip the root pseudo-component.
            if component == "/" { continue }

            currentPath = currentPath.appending(component: component)
            // We have a component to resolve, so the current entry must be a tree.
            guard current.type == .tree else {
                throw FileSystemError(.notDirectory, currentPath)
            }

            // Fetch the tree.
            let tree = try getTree(current.hash)

            // Search the tree for the component.
            //
            // FIXME: This needs to be optimized, somewhere.
            guard let index = tree.contents.firstIndex(where: { $0.name == component }) else {
                return nil
            }

            current = tree.contents[index]
        }

        return current
    }

    // FIXME: TOMER make async
    private func getTree(_ hash: Hash) throws -> Tree {
        // Check the cache.
        if let tree = trees[hash] {
            return tree
        }

        // Otherwise, load it.
        let tree = try temp_await { repository.read(tree: hash, completion: $0) }
        self.trees[hash] = tree
        return tree
    }

    func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
        do {
            return try self.getEntry(path) != nil
        } catch {
            return false
        }
    }

    func isFile(_ path: AbsolutePath) -> Bool {
        do {
            if let entry = try getEntry(path), entry.type != .tree {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isDirectory(_ path: AbsolutePath) -> Bool {
        do {
            if let entry = try getEntry(path), entry.type == .tree {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isSymlink(_ path: AbsolutePath) -> Bool {
        do {
            if let entry = try getEntry(path), entry.type == .symlink {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isExecutableFile(_ path: AbsolutePath) -> Bool {
        if let entry = try? getEntry(path), entry.type == .executableBlob {
            return true
        }
        return false
    }

    public var currentWorkingDirectory: AbsolutePath? {
        return AbsolutePath("/")
    }

    func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
        fatalError("Unsupported")
    }

    func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        guard let entry = try getEntry(path) else {
            throw FileSystemError(.noEntry, path)
        }
        guard entry.type == .tree else {
            throw FileSystemError(.notDirectory, path)
        }

        return try self.getTree(entry.hash).contents.map { $0.name }
    }

    // FIXME: TOMER make async
    func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        guard let entry = try getEntry(path) else {
            throw FileSystemError(.noEntry, path)
        }
        guard entry.type != .tree else {
            throw FileSystemError(.isDirectory, path)
        }
        guard entry.type != .symlink else {
            assertionFailure("FIXME: not implemented")
            throw InternalError("Not Implemented")
        }
        return try temp_await { self.repository.read(blob: entry.hash, completion: $0) }
    }

    // MARK: Unsupported methods.

    public var homeDirectory: AbsolutePath {
        fatalError("unsupported")
    }

    public var cachesDirectory: AbsolutePath? {
        fatalError("unsupported")
    }

    func createDirectory(_ path: AbsolutePath) throws {
        throw FileSystemError(.unsupported, path)
    }

    func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        throw FileSystemError(.unsupported, path)
    }

    func createSymbolicLink(_ path: AbsolutePath, pointingAt destination: AbsolutePath, relative: Bool) throws {
        throw FileSystemError(.unsupported, path)
    }

    func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        throw FileSystemError(.unsupported, path)
    }

    func removeFileTree(_ path: AbsolutePath) throws {
        throw FileSystemError(.unsupported, path)
    }

    func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
        throw FileSystemError(.unsupported, path)
    }

    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        fatalError("will never be supported")
    }

    func move(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        fatalError("will never be supported")
    }
}

// MARK: - Errors

private struct GitShellError: Error {
    let result: ProcessResult
}

private enum GitInterfaceError: Swift.Error {
    /// This indicates a problem communicating with the `git` tool.
    case malformedResponse(String)

    /// This indicates that a fatal error was encountered
    case fatalError
}

public struct GitRepositoryError: Error, CustomStringConvertible, DiagnosticLocationProviding {
    public let path: AbsolutePath
    public let message: String
    public let result: ProcessResult

    public struct Location: DiagnosticLocation {
        public let path: AbsolutePath
        public var description: String {
            return self.path.pathString
        }
    }

    public var diagnosticLocation: DiagnosticLocation? {
        return Location(path: self.path)
    }

    public var description: String {
        let stdout = (try? self.result.utf8Output()) ?? ""
        let stderr = (try? self.result.utf8stderrOutput()) ?? ""
        let output = (stdout + stderr).spm_chomp().spm_multilineIndent(count: 4)
        return "\(self.message):\n\(output)"
    }
}

public struct GitCloneError: Error, CustomStringConvertible, DiagnosticLocationProviding {
    public let repository: RepositorySpecifier
    public let message: String
    public let result: ProcessResult

    public struct Location: DiagnosticLocation {
        public let repository: RepositorySpecifier
        public var description: String {
            return self.repository.url
        }
    }

    public var diagnosticLocation: DiagnosticLocation? {
        return Location(repository: self.repository)
    }

    public var description: String {
        let stdout = (try? self.result.utf8Output()) ?? ""
        let stderr = (try? self.result.utf8stderrOutput()) ?? ""
        let output = (stdout + stderr).spm_chomp().spm_multilineIndent(count: 4)
        return "\(self.message):\n\(output)"
    }
}
