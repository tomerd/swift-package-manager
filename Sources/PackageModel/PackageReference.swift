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
import struct Foundation.URL

/// A package reference.
///
/// This represents a reference to a package containing its identity and location.
public struct PackageReference: Codable {
    /// The kind of package reference.
    public enum Kind: Codable, Equatable, Hashable, JSONMappable, JSONSerializable  {
        /// A root package.
        case root(AbsolutePath)

        /// A non-root local package.
        case local(AbsolutePath)

        /// A remote package.
        case remote(URL)

        public var location: String {
            get {
                switch self {
                case .root(let path):
                    return path.pathString
                case .local(let path):
                    return path.pathString
                case .remote(let url):
                    return url.absoluteString
                }
            }
        }

        public func isRoot() -> Bool {
            switch self {
            case .root:
                return true
            default:
                return false
            }
        }

        public func isLocal() -> Bool {
            switch self {
            case .local:
                return true
            default:
                return false
            }
        }

        public func isRemote() -> Bool {
            switch self {
            case .remote:
                return true
            default:
                return false
            }
        }

        public init(from decoder: Decoder) throws {
            fatalError()
        }

        public func encode(to encoder: Encoder) throws {
            fatalError()
        }

        public static func == (lhs: PackageReference.Kind, rhs: PackageReference.Kind) -> Bool {
            fatalError()
        }

        public init(json: JSON) throws {
            fatalError()
        }

        public func toJSON() -> JSON {
            fatalError()
        }
    }

    /// The identity of the package.
    public let identity: PackageIdentity2

    /// The path of the package.
    ///
    /// This path of package  on disk.
    //public let path: AbsolutePath

    /// The kind of package: root, local, or remote.
    public let kind: Kind

    public var location: String {
        get {
            self.kind.location
        }
    }
    
    /// Create a package reference given its identity and repository.
    public init(identity: PackageIdentity2, kind: Kind/*, path: AbsolutePath*/) {
        self.identity = identity
        self.kind = kind
        //self.path = path
    }

    /// Create a new package reference object with the given name.
    @available(*, deprecated)
    public func with(newName: String) -> PackageReference {
        return PackageReference(identity: PackageIdentity2(newName), kind: self.kind)
    }

    public static func root(identity: PackageIdentity2, path: AbsolutePath) -> PackageReference {
        self.init(identity: identity, kind: .root(path))
    }

    public static func local(identity: PackageIdentity2, path: AbsolutePath) -> PackageReference  {
        self.init(identity: identity, kind: .local(path))
    }

    public static func remote(identity: PackageIdentity2, url: URL) -> PackageReference {
        self.init(identity: identity, kind: .remote(url))
    }

    // FIXME
    public static func local(identity: PackageIdentity2, path: String) -> PackageReference  {
        self.local(identity: identity, path: AbsolutePath(path))
    }

    // FIXME
    public static func remote(identity: PackageIdentity2, url: String) -> PackageReference {
        Self.remote(identity: identity, url: URL(string: url)!)
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
        return "\(self.identity)\(self.kind.location.isEmpty ? "" : "[\(self.kind.location)]")"
    }
}

extension PackageReference: JSONMappable, JSONSerializable {
    public init(json: JSON) throws {
        let identity: PackageIdentity2
        // backwards compatibility
        if let id: PackageIdentity2 = json.get("identity") {
            identity = id
        } else if let name: String = json.get("name") {
            identity = PackageIdentity2(name)
        } else {
            throw InternalError("invalid package reference JSON, unknown package identity")
        }
        //self._name = json.get("name")
        self.identity = identity

        // backwards compatibility
        // Support previous version of PackageReference that contained an `isLocal` property.
        if let isLocal: Bool = json.get("isLocal") {
            let path: String = try json.get("path")
            self.kind = isLocal ? .local(AbsolutePath(path)) : .remote(URL(string: path)!)
        } else if let path: String = json.get("path")  {
            let isRemote = TSCUtility.URL.scheme(path) != nil
            self.kind = isRemote ? .remote(URL(string: path)!) : .local(AbsolutePath(path))
        } else {
            self.kind = try json.get("kind")
        }
        // FIXME
        //self._name = nil
    }

    public func toJSON() -> JSON {
        return .init([
            //"name": self.name.toJSON(),
            "identity": self.identity,
            //"path": self.path,
            "kind": self.kind,
        ])
    }
}
