/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic

/// Specifies a repository address.
public struct RepositorySpecifier: Hashable, Codable {
    /// The URL of the repository.
    public let url: String

    /// Create a specifier.
    public init(url: String) {
        self.url = url
    }

    /// A unique identifier for this specifier.
    ///
    /// This identifier is suitable for use in a file system path, and
    /// unique for each repository.
    public var fileSystemIdentifier: String {
        // Use first 8 chars of a stable hash.
        let hash = SHA256().hash(url).hexadecimalRepresentation
        let suffix = hash.dropLast(hash.count - 8)

        return basename + "-" + suffix
    }

    /// Returns the cleaned basename for the specifier.
    public var basename: String {
        var basename = url.components(separatedBy: "/").last(where: { !$0.isEmpty }) ?? ""
        if basename.hasSuffix(".git") {
            basename = String(basename.dropLast(4))
        }
        return basename
    }
}

extension RepositorySpecifier: CustomStringConvertible {
    public var description: String {
        return url
    }
}

extension RepositorySpecifier: JSONMappable, JSONSerializable {
    public init(json: JSON) throws {
        guard case .string(let url) = json else {
            throw JSON.MapError.custom(key: nil, message: "expected string, got \(json)")
        }
        self.url = url
    }

    public func toJSON() -> JSON {
        return .string(url)
    }
}

/// A repository provider.
///
/// This protocol defines the lower level interface used to to access
/// repositories. High-level clients should access repositories via a
/// `RepositoryManager`.
public protocol RepositoryProvider {
    /// Fetch the complete repository at the given location to `path`.
    ///
    /// - Parameters:
    ///   - repository: The specifier of the repository to fetch.
    ///   - path: The destiantion path for the fetch.
    ///   - completion: Callback when complete
    func fetch(repository: RepositorySpecifier, to path: AbsolutePath, completion: @escaping (Result<Void, Error>) -> Void)

    /// Open the given repository.
    ///
    /// - Parameters:
    ///   - repository: The specifier of the original repository from which the
    ///     local clone repository was created.
    ///   - path: The location of the repository on disk, at which the
    ///     repository has previously been created via `fetch`.
    ///   - completion: Callback when complete
    func open(repository: RepositorySpecifier, at path: AbsolutePath, completion: @escaping (Result<Repository, Error>) -> Void)

    /// Clone a managed repository into a working copy at on the local file system.
    ///
    /// Once complete, the repository can be opened using `openCheckout`. Note
    /// that there is no requirement that the files have been materialized into
    /// the file system at the completion of this call, since it will always be
    /// followed by checking out the cloned working copy at a particular ref.
    ///
    /// - Parameters:
    ///   - repository: The specifier of the original repository from which the
    ///     local clone repository was created.
    ///   - sourcePath: The location of the repository on disk, at which the
    ///     repository has previously been created via `fetch`.
    ///   - destinationPath: The path at which to create the working copy; it is
    ///     expected to be non-existent when called.
    ///   - editable: The checkout is expected to be edited by users.
    ///   - completion: Callback when complete
    func cloneCheckout(
        repository: RepositorySpecifier,
        at sourcePath: AbsolutePath,
        to destinationPath: AbsolutePath,
        editable: Bool, completion: @escaping (Result<Void, Error>) -> Void)

    /// Returns true if a working repository exists at `path`
    func checkoutExists(at path: AbsolutePath, completion: @escaping (Result<Bool, Error>) -> Void)

    /// Open a working repository copy.
    ///
    /// - Parameters:
    ///   - path: The location of the repository on disk, at which the repository
    ///     has previously been created via `cloneCheckout`.
    ///   - completion: Callback when complete
    func openCheckout(at path: AbsolutePath, completion: @escaping (Result<WorkingCheckout, Error>) -> Void)

    /// Copies the repository at path `from` to path `to`.
    /// - Parameters:
    ///   - sourcePath: the source path.
    ///   - destinationPath: the destination  path.
    ///   - completion: Callback when complete
    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath, completion: @escaping (Result<Void, Error>) -> Void)
}


/// Abstract repository operations.
///
/// This interface provides access to an abstracted representation of a
/// repository which is ultimately owned by a `RepositoryManager`. This interface
/// is designed in such a way as to provide the minimal facilities required by
/// the package manager to gather basic information about a repository, but it
/// does not aim to provide all of the interfaces one might want for working
/// with an editable checkout of a repository on disk.
///
/// The goal of this design is to allow the `RepositoryManager` a large degree of
/// flexibility in the storage and maintenance of its underlying repositories.
///
/// This protocol is designed under the assumption that the repository can only
/// be mutated via the functions provided here; thus, e.g., `tags` is expected
/// to be unchanged through the lifetime of an instance except as otherwise
/// documented. The behavior when this assumption is violated is undefined,
/// although the expectation is that implementations should throw or crash when
/// an inconsistency can be detected.
public protocol Repository {
    /// Get the list of tags in the repository.
    func tags(completion: @escaping (Result<[String], Error>) -> Void)

    /// Resolve the revision for a specific tag.
    ///
    /// - Precondition: The `tag` should be a member of `tags`.
    /// - Throws: If a error occurs accessing the named tag.
    func resolveRevision(tag: String, completion: @escaping (Result<Revision, Error>) -> Void)

    /// Resolve the revision for an identifier.
    ///
    /// The identifier can be a branch name or a revision identifier.
    ///
    /// - Throws: If the identifier can not be resolved.
    func resolveRevision(identifier: String, completion: @escaping (Result<Revision, Error>) -> Void)

    /// Fetch and update the repository from its remote.
    ///
    /// - Throws: If an error occurs while performing the fetch operation.
    func fetch(completion: @escaping (Result<Void, Error>) -> Void)

    /// Returns true if the given revision exists.
    func exists(revision: Revision, completion: @escaping (Result<Bool, Error>) -> Void)

    /// Open an immutable file system view for a particular revision.
    ///
    /// This view exposes the contents of the repository at the given revision
    /// as a file system rooted inside the repository. The repository must
    /// support opening multiple views concurrently, but the expectation is that
    /// clients should be prepared for this to be inefficient when performing
    /// interleaved accesses across separate views (i.e., the repository may
    /// back the view by an actual file system representation of the
    /// repository).
    ///
    /// It is expected behavior that attempts to mutate the given FileSystem
    /// will fail or crash.
    ///
    /// - Throws: If a error occurs accessing the revision.
    func openFileView(revision: Revision, completion: @escaping (Result<FileSystem, Error>) -> Void)
}

/// An editable checkout of a repository (i.e. a working copy) on the local file
/// system.
public protocol WorkingCheckout {
    /// Get the list of tags in the repository.
    func tags(completion: @escaping (Result<[String], Error>) -> Void)

    /// Get the current revision.
    func getCurrentRevision(completion: @escaping (Result<Revision, Error>) -> Void)

    /// Fetch and update the repository from its remote.
    ///
    /// - Throws: If an error occurs while performing the fetch operation.
    func fetch(completion: @escaping (Result<Void, Error>) -> Void)

    /// Query whether the checkout has any commits which are not pushed to its remote.
    func hasUnpushedCommits(completion: @escaping (Result<Bool, Error>) -> Void)

    /// This check for any modified state of the repository and returns true
    /// if there are uncommited changes.
    func hasUncommittedChanges(completion: @escaping (Result<Bool, Error>) -> Void)

    /// Check out the given tag.
    func checkout(tag: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// Check out the given revision.
    func checkout(revision: Revision, completion: @escaping (Result<Void, Error>) -> Void)

    /// Returns true if the given revision exists.
    func exists(revision: Revision, completion: @escaping (Result<Bool, Error>) -> Void)

    /// Create a new branch and checkout HEAD to it.
    ///
    /// Note: It is an error to provide a branch name which already exists.
    func checkout(newBranch: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// Returns true if there is an alternative store in the checkout and it is valid.
    func isAlternateObjectStoreValid(completion: @escaping (Result<Bool, Error>) -> Void)

    /// Returns true if the file at `path` is ignored by `git`
    func areIgnored(_ paths: [AbsolutePath], completion: @escaping (Result<[Bool], Error>) -> Void)
}

/// A single repository revision.
public struct Revision: Hashable {
    /// A precise identifier for a single repository revision, in a repository-specified manner.
    ///
    /// This string is intended to be opaque to the client, but understandable
    /// by a user. For example, a Git repository might supply the SHA1 of a
    /// commit, or an SVN repository might supply a string such as 'r123'.
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

extension Revision: JSONMappable {
    public init(json: JSON) throws {
        guard case .string(let identifier) = json else {
            throw JSON.MapError.custom(key: nil, message: "expected string, got \(json)")
        }
        self.init(identifier: identifier)
    }
}
