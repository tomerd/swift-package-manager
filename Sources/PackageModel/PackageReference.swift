/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import TSCBasic
import TSCUtility

/// A package reference.
///
/// This represents a reference to a package containing its identity and location.
public struct PackageReference: Codable {
    /// The kind of package reference.
    public enum Kind: String, Codable, Equatable {
        /// A root package.
        case root

        /// A non-root local package.
        case local

        /// A remote package.
        case remote
    }

    /// Compute the default name of a package given its URL.
    /*@available(*, deprecated)
    public static func computeDefaultName(fromURL url: String) -> String {
        #if os(Windows)
        let isSeparator : (Character) -> Bool = { $0 == "/" || $0 == "\\" }
        #else
        let isSeparator : (Character) -> Bool = { $0 == "/" }
        #endif

        // Get the last path component of the URL.
        // Drop the last character in case it's a trailing slash.
        var endIndex = url.endIndex
        if let lastCharacter = url.last, isSeparator(lastCharacter) {
            endIndex = url.index(before: endIndex)
        }

        let separatorIndex = url[..<endIndex].lastIndex(where: isSeparator)
        let startIndex = separatorIndex.map { url.index(after: $0) } ?? url.startIndex
        var lastComponent = url[startIndex..<endIndex]

        // Strip `.git` suffix if present.
        if lastComponent.hasSuffix(".git") {
            lastComponent = lastComponent.dropLast(4)
        }

        return String(lastComponent)
    }*/

    /// The identity of the package.
    public let identity: PackageIdentity2

    /// The name of the package, if available.
    /*@available(*, deprecated)
    public var name: String {
        _name ?? Self.computeDefaultName(fromURL: path)
    }
    private let _name: String?*/

    /// The path of the package.
    ///
    /// This could be a remote repository, local repository or local package.
    // FIXME: do something better than this
    public let path: String

    /// The kind of package: root, local, or remote.
    public let kind: Kind

    // FIXME: remove - used in tests
    @available(*, deprecated)
    public init(identity: PackageIdentity, kind: Kind = .remote, path: String) {
        self.identity = PackageIdentity2(identity.description)
        self.kind = kind
        //self._name = name
        self.path = path
    }

    /// Create a package reference given its identity and repository.
    public init(identity: PackageIdentity2, kind: Kind, path: String) {
        self.identity = identity
        self.kind = kind
        self.path = path
        // FIXME
        //self._name = identity.description
    }

    /// Create a new package reference object with the given name.
    @available(*, deprecated)
    public func with(newName: String) -> PackageReference {
        return PackageReference(identity: PackageIdentity2(newName), kind: self.kind, path: self.path)
    }
}

extension PackageReference: Equatable {
    public static func ==(lhs: PackageReference, rhs: PackageReference) -> Bool {
        return lhs.identity == rhs.identity
    }
}

extension PackageReference: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.identity)
    }
}

extension PackageReference: CustomStringConvertible {
    public var description: String {
        return "\(self.identity)\(path.isEmpty ? "" : "[\(path)]")"
    }
}

extension PackageReference: JSONMappable, JSONSerializable {
    public init(json: JSON) throws {
        let identity: PackageIdentity2
        // backwards compatibility
        if let id = json.get("identity") as PackageIdentity2? {
            identity = id
        } else if let name = json.get("name") as String? {
            identity = PackageIdentity2(name)
        } else {
            throw InternalError("invalid package reference JSON, unknown package identity")
        }
        //self._name = json.get("name")
        self.identity = identity
        self.path = try json.get("path")

        // Support previous version of PackageReference that contained an `isLocal` property.
        if let isLocal: Bool = json.get("isLocal") {
            self.kind = isLocal ? .local : .remote
        } else {
            self.kind = try Kind(rawValue: json.get("kind"))!
        }
        // FIXME
        //self._name = nil
    }

    public func toJSON() -> JSON {
        return .init([
            //"name": self.name.toJSON(),
            "identity": self.identity,
            "path": self.path,
            "kind": self.kind.rawValue,
        ])
    }
}
