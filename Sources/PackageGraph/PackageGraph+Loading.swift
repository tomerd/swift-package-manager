/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import TSCBasic
import SourceControl
import PackageLoading
import PackageModel
import TSCUtility

extension PackageGraph {

    /// Load the package graph for the given package path.
    @available(*, deprecated)
    public static func load(
        root: PackageGraphRoot,
        mirrors: DependencyMirrors = [:],
        additionalFileRules: [FileRuleDescription] = [],
        externalManifests: [Manifest],
        requiredDependencies: Set<PackageReference> = [],
        unsafeAllowedPackages: Set<PackageReference> = [],
        remoteArtifacts: [RemoteArtifact] = [],
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion] = MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
        diagnostics: DiagnosticsEngine,
        fileSystem: FileSystem = localFileSystem,
        shouldCreateMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false
    ) throws -> PackageGraph {
        // FIXME
        fatalError()
    }

    public static func load(
        root: PackageGraphRoot54,
        externalManifests: [ManifestContext: Manifest],
        additionalFileRules: [FileRuleDescription] = [],
        requiredDependencies: Set<PackageReference> = [],
        unsafeAllowedPackages: Set<PackageReference> = [],
        remoteArtifacts: [RemoteArtifact] = [],
        xcTestMinimumDeploymentTargets: [PackageModel.Platform:PlatformVersion] = MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
        diagnostics: DiagnosticsEngine,
        fileSystem: FileSystem = localFileSystem,
        shouldCreateMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false
    ) throws -> PackageGraph {

        // Create a map of the manifests, keyed by their identity.
        //
        // FIXME: For now, we have to compute the identity of dependencies from
        // the URL but that shouldn't be needed after <rdar://problem/33693433>
        // Ensure that identity and package name are the same once we have an
        // API to specify identity in the manifest file
        /*let manifestMapSequence = (root.manifests + externalManifests).map({ (PackageIdentity(url: $0.url), $0) })
        let manifestMap = Dictionary(uniqueKeysWithValues: manifestMapSequence)
        */

        // FIXME: confirm merging logic is correct (prefer root over external)
        var manifestMap = root.packageManifests.reduce(into: [PackageIdentity2: (context: ManifestContext, manifest: Manifest)](), { partial, item in
            let context = ManifestContext(package: item.key)
            partial[item.key.identity] = (context, item.value)
        })
        manifestMap.merge(externalManifests.reduce(into: [PackageIdentity2: (ManifestContext, Manifest)](), { partial, item in
            partial[item.key.identity] = (item.key, item.value)
        }), uniquingKeysWith: { root, external in root })

        let successors: (GraphLoadingNode) -> [GraphLoadingNode] = { node in
            node.requiredDependencies().compactMap({ dependency in
                //let url = mirrors.effectiveURL(forURL: dependency.url)
                return manifestMap[dependency.identity].map { item in
                    GraphLoadingNode(context: item.context, manifest: item.manifest, productFilter: dependency.productFilter)
                }
            })
        }

        // Construct the root manifest and root dependencies set.
        let rootManifestSet = Set(root.packageManifests.values)
        let rootDependencies = Set(root.dependencies.compactMap {
            manifestMap[$0.identity]?.manifest
        })
        let rootManifestNodes = root.packageManifests.map { package, manifest -> GraphLoadingNode in
            let context = ManifestContext(package: package)
            return GraphLoadingNode(context: context, manifest: manifest, productFilter: .everything)
        }
        let rootDependencyNodes = root.dependencies.lazy.compactMap { (dependency: PackageDependencyDescription) -> GraphLoadingNode? in
            manifestMap[dependency.identity].map { item in
                GraphLoadingNode(context: item.context, manifest: item.manifest, productFilter: dependency.productFilter)
            }
        }

        let inputManifests = rootManifestNodes + rootDependencyNodes

        // Collect the manifests for which we are going to build packages.
        var allManifests: [GraphLoadingNode]

        // Detect cycles in manifest dependencies.
        if let cycle = findCycle(inputManifests, successors: successors) {
            diagnostics.emit(PackageGraphError.cycleDetected(cycle))
            // Break the cycle so we can build a partial package graph.
            allManifests = inputManifests.filter({ $0.manifest != cycle.cycle[0] })
        } else {
            // Sort all manifests toplogically.
            allManifests = try topologicalSort(inputManifests, successors: successors)
        }
        var flattenedManifests: [PackageIdentity2: GraphLoadingNode] = [:]
        for node in allManifests {
            if let existing = flattenedManifests[node.identity] {
                let merged = GraphLoadingNode(
                    identity: node.identity,
                    kind: node.kind,
                    path: node.path,
                    manifest: node.manifest,
                    productFilter: existing.productFilter.union(node.productFilter)
                )
                flattenedManifests[node.identity] = merged
            } else {
                flattenedManifests[node.identity] = node
            }
        }
        allManifests = flattenedManifests.values.sorted(by: { $0.identity < $1.identity })

        // Create the packages.
        var manifestToPackage: [Manifest: Package] = [:]
        for node in allManifests {
            let manifest = node.manifest

            // Derive the path to the package.
            let packagePath = node.path.parentDirectory

            // FIXME
            let packageLocation = PackageLocation.Local(name: node.identity.description, packagePath: packagePath)
            diagnostics.with(location: packageLocation) { diagnostics in
                diagnostics.wrap {
                    // Create a package from the manifest and sources.
                    let builder = PackageBuilder(
                        identity: node.identity,
                        kind: node.kind,
                        path: packagePath,
                        manifest: manifest,
                        productFilter: node.productFilter,
                        additionalFileRules: additionalFileRules,
                        remoteArtifacts: remoteArtifacts,
                        xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets,
                        fileSystem: fileSystem,
                        diagnostics: diagnostics,
                        shouldCreateMultipleTestProducts: shouldCreateMultipleTestProducts,
                        createREPLProduct: node.kind.isRoot() ? createREPLProduct : false
                    )
                    let package = try builder.construct()
                    manifestToPackage[manifest] = package

                    // Throw if any of the non-root package is empty.
                    if package.targets.isEmpty // System packages have targets in the package but not the manifest.
                        && package.manifest.targets.isEmpty // An unneeded dependency will not have loaded anything from the manifest.
                        && !node.kind.isRoot() {
                            throw PackageGraphError.noModules(package)
                    }
                }
            }
        }

        // Resolve dependencies and create resolved packages.
        let resolvedPackages = try createResolvedPackages(
            allManifests: allManifests,
            //mirrors: mirrors,
            manifestToPackage: manifestToPackage,
            rootManifestSet: rootManifestSet,
            unsafeAllowedPackages: unsafeAllowedPackages,
            diagnostics: diagnostics
        )

        let rootPackages = resolvedPackages.filter{ rootManifestSet.contains($0.manifest) }

        checkAllDependenciesAreUsed(rootPackages, diagnostics)

        return try PackageGraph(
            rootPackages: rootPackages,
            rootDependencies: resolvedPackages.filter{ rootDependencies.contains($0.manifest) },
            dependencies: requiredDependencies
        )
    }
}

private func checkAllDependenciesAreUsed(_ rootPackages: [ResolvedPackage], _ diagnostics: DiagnosticsEngine) {
    for package in rootPackages {
        // List all dependency products dependended on by the package targets.
        let productDependencies: Set<ResolvedProduct> = Set(package.targets.flatMap({ target in
            return target.dependencies.compactMap({ targetDependency in
                switch targetDependency {
                case .product(let product, _):
                    return product
                case .target:
                    return nil
                }
            })
        }))

        for dependency in package.dependencies {
            // We continue if the dependency contains executable products to make sure we don't
            // warn on a valid use-case for a lone dependency: swift run dependency executables.
            guard !dependency.products.contains(where: { $0.type == .executable }) else {
                continue
            }
            // Skip this check if this dependency is a system module because system module packages
            // have no products.
            //
            // FIXME: Do/should we print a warning if a dependency has no products?
            if dependency.products.isEmpty && dependency.targets.filter({ $0.type == .systemModule }).count == 1 {
                continue
            }

            let dependencyIsUsed = dependency.products.contains(where: productDependencies.contains)
            if !dependencyIsUsed {
                // FIXME
                diagnostics.emit(.unusedDependency(dependency.identity.description))
            }
        }
    }
}

/// Create resolved packages from the loaded packages.
private func createResolvedPackages(
    allManifests: [GraphLoadingNode],
    //mirrors: DependencyMirrors,
    manifestToPackage: [Manifest: Package],
    // FIXME: This shouldn't be needed once <rdar://problem/33693433> is fixed.
    rootManifestSet: Set<Manifest>,
    unsafeAllowedPackages: Set<PackageReference>,
    diagnostics: DiagnosticsEngine
) throws -> [ResolvedPackage] {

    // Create package builder objects from the input manifests.
    let packageBuilders: [ResolvedPackageBuilder] = allManifests.compactMap({ node in
        guard let package = manifestToPackage[node.manifest] else {
            return nil
        }
        let isAllowedToVendUnsafeProducts = unsafeAllowedPackages.contains{ $0.identity == package.identity }
        return ResolvedPackageBuilder(
            package,
            productFilter: node.productFilter,
            isAllowedToVendUnsafeProducts: isAllowedToVendUnsafeProducts
        )
    })

    // Create a map of package builders keyed by the package identity.
    let packageMapByIdentity: [PackageIdentity2: ResolvedPackageBuilder] = packageBuilders.spm_createDictionary{
        //let identity = PackageIdentity(url: $0.package.manifest.url)
        return ($0.package.identity, $0)
    }
    //let packageMapByName: [String: ResolvedPackageBuilder] = packageBuilders.spm_createDictionary{ ($0.package.name, $0) }

    // In the first pass, we wire some basic things.
    for packageBuilder in packageBuilders {
        let package = packageBuilder.package

        // Establish the manifest-declared package dependencies.
        packageBuilder.dependencies = package.manifest.dependenciesRequired(for: packageBuilder.productFilter)
            .compactMap { dependency in
                // Use the package identity to lookup the dependency.
                if let resolvedPackage = packageMapByIdentity[dependency.identity] {
                    return resolvedPackage
                }

                return nil

                // FIXME: confirm this is not required any longer
                /*
                // Use the package name to lookup the dependency. The package name will be present in packages with tools version >= 5.2.
                if let dependencyName = dependency.explicitName, let resolvedPackage = packageMapByName[dependencyName] {
                    return resolvedPackage
                }

                // Otherwise, look it up by its identity.
                let url = mirrors.effectiveURL(forURL: dependency.url)
                let resolvedPackage = packageMapByIdentity[PackageIdentity(url: url)]

                // We check that the explicit package dependency name matches the package name.
                if let resolvedPackage = resolvedPackage,
                    let explicitDependencyName = dependency.explicitName,
                    resolvedPackage.package.name != dependency.explicitName
                {
                    let error = PackageGraphError.incorrectPackageDependencyName(
                        dependencyName: explicitDependencyName,
                        dependencyURL: dependency.url,
                        packageName: resolvedPackage.package.name)
                    let diagnosticLocation = PackageLocation.Local(name: package.name, packagePath: package.path)
                    diagnostics.emit(error, location: diagnosticLocation)
                }

                return resolvedPackage
                */
            }

        // Create target builders for each target in the package.
        let targetBuilders = package.targets.map({ ResolvedTargetBuilder(target: $0, diagnostics: diagnostics) })
        packageBuilder.targets = targetBuilders

        // Establish dependencies between the targets. A target can only depend on another target present in the same package.
        let targetMap = targetBuilders.spm_createDictionary({ ($0.target, $0) })
        for targetBuilder in targetBuilders {
            targetBuilder.dependencies += try targetBuilder.target.dependencies.compactMap { dependency in
                switch dependency {
                case .target(let targetName, let conditions):
                    guard let target = targetMap[targetName] else {
                        throw InternalError("unknown target \(targetName)")
                    }
                    return .target(target, conditions: conditions)
                case .product:
                    return nil
                }
            }
        }

        // Create product builders for each product in the package. A product can only contain a target present in the same package.
        packageBuilder.products = try package.products.map{
            try ResolvedProductBuilder(product: $0, packageBuilder: packageBuilder, targets: $0.targets.map {
                guard let target = targetMap[$0] else {
                    throw InternalError("unknown target \($0)")
                }
                return target
            })
        }
    }

    // Find duplicate products in the package graph.
    let duplicateProducts = packageBuilders
        .flatMap({ $0.products })
        .map({ $0.product })
        .spm_findDuplicateElements(by: \.name)
        .map({ $0[0].name })

    // Emit diagnostics for duplicate products.
    for productName in duplicateProducts {
        let packages = packageBuilders
            .filter{ $0.products.contains(where: { $0.product.name == productName }) }
            .map{ $0.package.identity }
            .sorted()

        diagnostics.emit(PackageGraphError.duplicateProduct(product: productName, packages: packages))
    }

    // Remove the duplicate products from the builders.
    for packageBuilder in packageBuilders {
        packageBuilder.products = packageBuilder.products.filter({ !duplicateProducts.contains($0.product.name) })
    }

    // The set of all target names.
    var allTargetNames = Set<String>()

    // Track if multiple targets are found with the same name.
    var foundDuplicateTarget = false

    // Do another pass and establish product dependencies of each target.
    for packageBuilder in packageBuilders {
        let package = packageBuilder.package

        // The diagnostics location for this package.
        // FIXME
        let diagnosticLocation = { PackageLocation.Local(name: package.identity.description, packagePath: package.path) }

        // Get all implicit system library dependencies in this package.
        let implicitSystemTargetDeps = packageBuilder.dependencies
            .flatMap{ $0.targets }
            .filter{
                if case let systemLibrary as SystemLibraryTarget = $0.target {
                    return systemLibrary.isImplicit
                }
                return false
            }

        // Get all the products from dependencies of this package.
        let productDependencies = packageBuilder.dependencies
            .flatMap{ $0.products }
            .filter{ $0.product.type != .test }
        let productDependencyMap = productDependencies.spm_createDictionary({ ($0.product.name, $0) })

        // Establish dependencies in each target.
        for targetBuilder in packageBuilder.targets {
            // Record if we see a duplicate target.
            foundDuplicateTarget = foundDuplicateTarget || !allTargetNames.insert(targetBuilder.target.name).inserted

            // Directly add all the system module dependencies.
            targetBuilder.dependencies += implicitSystemTargetDeps.map { .target($0, conditions: []) }

            // Establish product dependencies.
            for case .product(let productRef, let conditions) in targetBuilder.target.dependencies {
                // Find the product in this package's dependency products.
                guard let product = productDependencyMap[productRef.name] else {
                    // Only emit a diagnostic if there are no other diagnostics.
                    // This avoids flooding the diagnostics with product not
                    // found errors when there are more important errors to
                    // resolve (like authentication issues).
                    if !diagnostics.hasErrors {
                        let error = PackageGraphError.productDependencyNotFound(name: productRef.name, target: targetBuilder.target.name)
                        diagnostics.emit(error, location: diagnosticLocation())
                    }
                    continue
                }

                // If package name is mentioned, ensure it is valid.
                if let packageIdentity = productRef.packageIdentity {
                    // Find the declared package and check that it contains
                    // the product we found above.
                    guard let dependencyPackage = packageMapByIdentity[packageIdentity], dependencyPackage.products.contains(product) else {
                        let error = PackageGraphError.productDependencyIncorrectPackage(name: productRef.name, package: packageIdentity)
                        diagnostics.emit(error, location: diagnosticLocation())
                        continue
                    }
                } else if packageBuilder.package.manifest.toolsVersion >= .v5_2 {
                    // Starting in 5.2, and target-based dependency, we require target product dependencies to
                    // explicitly reference the package containing the product, or for the product, package and
                    // dependency to share the same name. We don't check this in manifest loading for root-packages so
                    // we can provide a more detailed diagnostic here.
                    //let referencedPackageURL = mirrors.effectiveURL(forURL: product.packageBuilder.package.manifest.url)
                    let referencedPackageIdentity = packageBuilder.package.identity //PackageIdentity(url: referencedPackageURL)
                    guard let packageDependency = (packageBuilder.package.manifest.dependencies.first { package in
                        //let packageURL = mirrors.effectiveURL(forURL: package.url)
                        //let packageIdentity = PackageIdentity(url: packageURL)
                        return package.identity == referencedPackageIdentity
                    }) else {
                        throw InternalError("dependency reference for \(referencedPackageIdentity) not found")
                    }

                    // FIXME: clean up more
                    let packageIdentity = product.packageBuilder.package.identity
                    if productRef.packageIdentity != packageDependency.identity || packageDependency.identity != packageIdentity {
                        let error = PackageGraphError.productDependencyMissingPackage(
                            productName: productRef.name,
                            targetName: targetBuilder.target.name,
                            package: packageIdentity,
                            packageDependency: packageDependency
                        )
                        diagnostics.emit(error, location: diagnosticLocation())
                    }
                }

                targetBuilder.dependencies.append(.product(product, conditions: conditions))
            }
        }
    }

    // If a target with similar name was encountered before, we emit a diagnostic.
    if foundDuplicateTarget {
        for targetName in allTargetNames.sorted() {
            // Find the packages this target is present in.
            let packages = packageBuilders
                .filter({ $0.targets.contains(where: { $0.target.name == targetName }) })
                .map{ $0.package.identity }
                .sorted()
            if packages.count > 1 {
                diagnostics.emit(ModuleError.duplicateModule(targetName, packages: packages))
            }
        }
    }
    return try packageBuilders.map{ try $0.construct() }
}

/// A generic builder for `Resolved` models.
private class ResolvedBuilder<T>: ObjectIdentifierProtocol {

    /// The constucted object, available after the first call to `constuct()`.
    private var _constructedObject: T?

    /// Construct the object with the accumulated data.
    ///
    /// Note that once the object is constucted, future calls to
    /// this method will return the same object.
    final func construct() throws -> T {
        if let constructedObject = _constructedObject {
            return constructedObject
        }
        let constructedObject = try self.constructImpl()
        _constructedObject = constructedObject
        return constructedObject
    }

    /// The object construction implementation.
    func constructImpl() throws -> T {
        fatalError("Should be implemented by subclasses")
    }
}

/// Builder for resolved product.
private final class ResolvedProductBuilder: ResolvedBuilder<ResolvedProduct> {
    /// The reference to its package.
    unowned let packageBuilder: ResolvedPackageBuilder

    /// The product reference.
    let product: Product

    /// The target builders in the product.
    let targets: [ResolvedTargetBuilder]

    init(product: Product, packageBuilder: ResolvedPackageBuilder, targets: [ResolvedTargetBuilder]) {
        self.product = product
        self.packageBuilder = packageBuilder
        self.targets = targets
    }

    override func constructImpl() throws -> ResolvedProduct {
        return ResolvedProduct(
            product: product,
            targets: try targets.map{ try $0.construct() }
        )
    }
}

/// Builder for resolved target.
private final class ResolvedTargetBuilder: ResolvedBuilder<ResolvedTarget> {

    /// Enumeration to represent target dependencies.
    enum Dependency {

        /// Dependency to another target, with conditions.
        case target(_ target: ResolvedTargetBuilder, conditions: [PackageConditionProtocol])

        /// Dependency to a product, with conditions.
        case product(_ product: ResolvedProductBuilder, conditions: [PackageConditionProtocol])
    }

    /// The target reference.
    let target: Target

    /// The target dependencies of this target.
    var dependencies: [Dependency] = []

    /// The diagnostics engine.
    let diagnostics: DiagnosticsEngine

    init(target: Target, diagnostics: DiagnosticsEngine) {
        self.target = target
        self.diagnostics = diagnostics
    }

    func diagnoseInvalidUseOfUnsafeFlags(_ product: ResolvedProduct) throws {
        // Diagnose if any target in this product uses an unsafe flag.
        for target in try product.recursiveTargetDependencies() {
            let declarations = target.underlyingTarget.buildSettings.assignments.keys
            for decl in declarations {
                if BuildSettings.Declaration.unsafeSettings.contains(decl) {
                    diagnostics.emit(.productUsesUnsafeFlags(product: product.name, target: target.name))
                    break
                }
            }
        }
    }

    override func constructImpl() throws -> ResolvedTarget {
        let dependencies = try self.dependencies.map { dependency -> ResolvedTarget.Dependency in
            switch dependency {
            case .target(let targetBuilder, let conditions):
                return .target(try targetBuilder.construct(), conditions: conditions)
            case .product(let productBuilder, let conditions):
                let product = try productBuilder.construct()
                if !productBuilder.packageBuilder.isAllowedToVendUnsafeProducts {
                    try self.diagnoseInvalidUseOfUnsafeFlags(product)
                }
                return .product(product, conditions: conditions)
            }
        }

        return ResolvedTarget(target: target, dependencies: dependencies)
    }
}

/// Builder for resolved package.
private final class ResolvedPackageBuilder: ResolvedBuilder<ResolvedPackage> {

    /// The package reference.
    let package: Package

    /// The product filter applied to the package.
    let productFilter: ProductFilter

    /// The targets in the package.
    var targets: [ResolvedTargetBuilder] = []

    /// The products in this package.
    var products: [ResolvedProductBuilder] = []

    /// The dependencies of this package.
    var dependencies: [ResolvedPackageBuilder] = []

    let isAllowedToVendUnsafeProducts: Bool

    init(_ package: Package, productFilter: ProductFilter, isAllowedToVendUnsafeProducts: Bool) {
        self.package = package
        self.productFilter = productFilter
        self.isAllowedToVendUnsafeProducts = isAllowedToVendUnsafeProducts
    }

    override func constructImpl() throws -> ResolvedPackage {
        return ResolvedPackage(
            package: package,
            dependencies: try dependencies.map{ try $0.construct() },
            targets: try targets.map{ try $0.construct() },
            products: try products.map{ try  $0.construct() }
        )
    }
}

/// Finds the first cycle encountered in a graph.
///
/// This is different from the one in tools support core, in that it handles equality separately from node traversal. Nodes traverse product filters, but only the manifests must be equal for there to be a cycle.
fileprivate func findCycle(
    _ nodes: [GraphLoadingNode],
    successors: (GraphLoadingNode) throws -> [GraphLoadingNode]
) rethrows -> (path: [Manifest], cycle: [Manifest])? {
    // Ordered set to hold the current traversed path.
    var path = OrderedSet<Manifest>()

    // Function to visit nodes recursively.
    // FIXME: Convert to stack.
    func visit(
      _ node: GraphLoadingNode,
      _ successors: (GraphLoadingNode) throws -> [GraphLoadingNode]
    ) rethrows -> (path: [Manifest], cycle: [Manifest])? {
        // If this node is already in the current path then we have found a cycle.
        if !path.append(node.manifest) {
            let index = path.firstIndex(of: node.manifest)! // forced unwrap safe
            return (Array(path[path.startIndex..<index]), Array(path[index..<path.endIndex]))
        }

        for succ in try successors(node) {
            if let cycle = try visit(succ, successors) {
                return cycle
            }
        }
        // No cycle found for this node, remove it from the path.
        let item = path.removeLast()
        assert(item == node.manifest)
        return nil
    }

    for node in nodes {
        if let cycle = try visit(node, successors) {
            return cycle
        }
    }
    // Couldn't find any cycle in the graph.
    return nil
}
