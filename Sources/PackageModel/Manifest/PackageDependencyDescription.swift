/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic

/// Represents a package dependency.
public struct PackageDependencyDescription: Equatable, Codable, Hashable {

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

    /// The identity of the package dependency.
    public let identity: PackageIdentity

    /// The location of the package dependency.
    public let location: String

    // FIXME: we should simplify target based resolution so that
    // this is no longer required and can be removed
    // it is named verbosity so its not used for anything else
    // but target based dependency resolution
    public let explicitNameForTargetResolutionOnly: String?

    /// The dependency requirement.
    public let requirement: Requirement

    /// The products requested of the package dependency.
    public let productFilter: ProductFilter

    /// Create a package dependency.
    public init(
        identity: PackageIdentity,
        explicitNameForTargetResolutionOnly: String?,
        location: String,
        requirement: Requirement,
        productFilter: ProductFilter
    ) {
        self.identity = identity
        self.explicitNameForTargetResolutionOnly = explicitNameForTargetResolutionOnly
        self.location = location
        self.requirement = requirement
        self.productFilter = productFilter
    }

    /// Returns a new package dependency with the specified products.
    public func filtered(by productFilter: ProductFilter) -> PackageDependencyDescription {
        PackageDependencyDescription(identity: self.identity,
                                     explicitNameForTargetResolutionOnly: self.explicitNameForTargetResolutionOnly,
                                     location: self.location,
                                     requirement: self.requirement,
                                     productFilter: productFilter)
    }


    @available(*, deprecated, message: "move to tests")
    public init(
        name: String? = nil,
        url: String,
        requirement: Requirement,
        productFilter: ProductFilter = .everything
    ) {
        self.identity = PackageIdentity(url: url)
        self.explicitNameForTargetResolutionOnly = name
        self.location = url
        self.requirement = requirement
        self.productFilter = productFilter
    }
}

// FIXME: we should simplify target based resolution so that
// this is no longer required and can be removed
// it is named verbosity so its not used for anything else
// but target based dependency resolution
extension PackageDependencyDescription {
    public var nameForTargetResolutionOnly: String {
        if let explicitName = self.explicitNameForTargetResolutionOnly {
            return explicitName
        } else {
            return LegacyPackageIdentity.computeDefaultName(fromURL: self.location)
        }
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
