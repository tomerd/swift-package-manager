/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import TSCUtility

/// A package reference.
///
/// This represents a reference to a package containing its identity and location.
public struct PackageReference: Codable {
    /// The kind of package reference.
    public enum Kind: String, Codable {
        /// A root package.
        case root

        /// A non-root local package.
        case local

        /// A remote package.
        case remote
    }

    /// The identity of the package.
    public let identity: PackageIdentity

    /// The path of the package.
    ///
    /// This could be a remote repository, local repository or local package.
    public let path: String

    /// The kind of package: root, local, or remote.
    public let kind: Kind

    /// Create a package reference given its identity and repository.
    public init(identity: PackageIdentity, kind: Kind, path: String) {
        self.identity = identity
        self.kind = kind
        self.path = path
    }

    /// Create a new package reference object with the given name.
    public func with(newName: String) -> PackageReference {
        return PackageReference(identity: PackageIdentity(newName), kind: self.kind, path: self.path)
    }

    public static func root(identity: PackageIdentity, path: AbsolutePath) -> PackageReference {
        PackageReference(identity: identity, kind: .root, path: path.pathString)
    }

    public static func local(identity: PackageIdentity, path: AbsolutePath) -> PackageReference {
        PackageReference(identity: identity, kind: .local, path: path.pathString)
    }

    public static func remote(identity: PackageIdentity, url: String) -> PackageReference {
        PackageReference(identity: identity, kind: .remote, path: url)
    }
}

extension PackageReference: Equatable {
    public static func ==(lhs: PackageReference, rhs: PackageReference) -> Bool {
        return lhs.identity == rhs.identity
    }
}

extension PackageReference: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }
}

extension PackageReference: CustomStringConvertible {
    public var description: String {
        return "\(identity)\(path.isEmpty ? "" : "[\(path)]")"
    }
}

extension PackageReference: JSONMappable, JSONSerializable {
    public init(json: JSON) throws {
        //self._name = json.get("name")
        self.identity = try json.get("identity")
        self.path = try json.get("path")

        // Support previous version of PackageReference that contained an `isLocal` property.
        if let isLocal: Bool = json.get("isLocal") {
            kind = isLocal ? .local : .remote
        } else {
            kind = try Kind(rawValue: json.get("kind"))!
        }
    }

    public func toJSON() -> JSON {
        return .init([
            //"name": name.toJSON(),
            "identity": identity,
            "path": path,
            "kind": kind.rawValue,
        ])
    }
}
