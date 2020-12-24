/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import TSCBasic
import PackageLoading
import PackageModel
import TSCUtility

/// A node used while loading the packages in a resolved graph.
///
/// This node uses the product filter that was already finalized during resolution.
///
/// - SeeAlso: DependencyResolutionNode
public struct GraphLoadingNode: Equatable, Hashable {

    /// The package identity.
    public let identity: PackageIdentity2

    /// The package manifest path
    public let path: AbsolutePath

    /// The package manifest.
    public let manifest: Manifest

    /// The product filter applied to the package.
    public let productFilter: ProductFilter

    public init(identity: PackageIdentity2,
                path: AbsolutePath,
                manifest: Manifest,
                productFilter: ProductFilter) {
        self.identity = identity
        self.path = path
        self.manifest = manifest
        self.productFilter = productFilter
    }

    /// Returns the dependencies required by this node.
    internal func requiredDependencies() -> [PackageDependencyDescription] {
        return manifest.dependenciesRequired(for: productFilter)
    }
}

extension GraphLoadingNode: CustomStringConvertible {
    public var description: String {
        switch productFilter {
        case .everything:
            return self.identity.description
        case .specific(let set):
            return "\(self.identity)[\(set.sorted().joined(separator: ", "))]"
        }
    }
}
