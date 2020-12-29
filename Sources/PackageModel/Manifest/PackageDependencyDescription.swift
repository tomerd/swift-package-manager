/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic

/// Represents a package dependency.
public struct PackageDependencyDescription: Equatable, Codable {

    /// The dependency requirement.
    public enum Requirement: Equatable, Hashable {
        case exact(Version)
        case range(Range<Version>)
        case revision(String)
        case branch(String)
        case localPackage

        public static func upToNextMajor(from version: TSCUtility.Version) -> Requirement {
            return .range(version..<Version(version.major + 1, 0, 0))
        }

        public static func upToNextMinor(from version: TSCUtility.Version) -> Requirement {
            return .range(version..<Version(version.major, version.minor + 1, 0))
        }
    }

    // FIXME: remove this and use identity instead
    /// The name of the package dependency explicitly defined in the manifest, if any.
    //public let explicitName: String?

    // FIXME: remove this and use identity instead
    /// The name of the package dependency,
    /// either explicitly defined in the manifest,
    /// or derived from the URL.
    ///
    /// - SeeAlso: `explicitName`
    /// - SeeAlso: `url`
    //public let name: String

    /// The identity of the package dependency,
    /// either explicitly defined in the manifest,
    /// or derived from the location.
    public let identity: PackageIdentity

    /// The location of the package dependency.
    public let location: String

    /// The dependency requirement.
    public let requirement: Requirement

    /// The products requested of the package dependency.
    public let productFilter: ProductFilter

    // FIXME: remove this / move elsewhere. need a better model for location instead of string URL for both AbsolutePath and URLs
    // FIXME: SwiftPM can't handle file URLs with file:// scheme so we need to
    // strip that. We need to design a URL data structure for SwiftPM.
    /*let filePrefix = "file://"
    let normalizedLocation: String
    if location.hasPrefix(filePrefix) {
        normalizedLocation = AbsolutePath(String(location.dropFirst(filePrefix.count))).pathString
    } else {
        normalizedLocation = location
    }
    */

    // FIXME: tomer identity changes, used by tests - move there or refactor
    @available(*, deprecated)
    public init(
        name: String? = nil,
        url: String,
        requirement: Requirement,
        productFilter: ProductFilter = .everything
    ) {
        self.identity = name.map(PackageIdentity.init(name:)) ?? PackageIdentity(url: url)
        self.location = url
        self.requirement = requirement
        self.productFilter = productFilter
    }

    /// Create a package dependency.
    public init(
        identity: PackageIdentity,
        location: String,
        requirement: Requirement,
        productFilter: ProductFilter = .everything
    ) {
        self.identity = identity
        self.location = location
        self.requirement = requirement
        self.productFilter = productFilter
    }

    /// Returns a new package dependency with the specified products.
    public func filtered(by productFilter: ProductFilter) -> PackageDependencyDescription {
        PackageDependencyDescription(identity: self.identity,
                                     location: self.location,
                                     requirement: self.requirement,
                                     productFilter: productFilter)
    }
}

extension PackageDependencyDescription.Requirement: CustomStringConvertible {
    public var description: String {
        switch self {
        case .exact(let version):
            return version.description
        case .range(let range):
            return range.description
        case .revision(let revision):
            return "revision[\(revision)]"
        case .branch(let branch):
            return "branch[\(branch)]"
        case .localPackage:
            return "local"
        }
    }
}

extension PackageDependencyDescription.Requirement: Codable {
    private enum CodingKeys: String, CodingKey {
        case exact, range, revision, branch, localPackage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .exact(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .exact)
            try unkeyedContainer.encode(a1)
        case let .range(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .range)
            try unkeyedContainer.encode(CodableRange(a1))
        case let .revision(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .revision)
            try unkeyedContainer.encode(a1)
        case let .branch(a1):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .branch)
            try unkeyedContainer.encode(a1)
        case .localPackage:
            try container.encodeNil(forKey: .localPackage)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .exact:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(Version.self)
            self = .exact(a1)
        case .range:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(CodableRange<Version>.self)
            self = .range(a1.range)
        case .revision:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(String.self)
            self = .revision(a1)
        case .branch:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(String.self)
            self = .branch(a1)
        case .localPackage:
            self = .localPackage
        }
    }
}
