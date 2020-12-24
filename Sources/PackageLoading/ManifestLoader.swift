/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import TSCBasic
import PackageModel
import TSCUtility
import Foundation
public typealias FileSystem = TSCBasic.FileSystem

public enum ManifestParseError: Swift.Error {
    /// The manifest contains invalid format.
    case invalidManifestFormat(String, diagnosticFile: AbsolutePath?)

    /// The manifest was successfully loaded by swift interpreter but there were runtime issues.
    case runtimeManifestErrors([String])
}

/// Resources required for manifest loading.
///
/// These requirements are abstracted out to make it easier to add support for
/// using the package manager with alternate toolchains in the future.
public protocol ManifestResourceProvider {
    /// The path of the swift compiler.
    var swiftCompiler: AbsolutePath { get }

    /// The path of the library resources.
    var libDir: AbsolutePath { get }

    /// The path to SDK root.
    ///
    /// If provided, it will be passed to the swift interpreter.
    var sdkRoot: AbsolutePath? { get }

    /// The bin directory.
    var binDir: AbsolutePath? { get }

    /// Extra flags to pass the Swift compiler.
    var swiftCompilerFlags: [String] { get }

    /// XCTest Location
    var xctestLocation: AbsolutePath? { get }
}

/// Default implementation for the resource provider.
public extension ManifestResourceProvider {

    var sdkRoot: AbsolutePath? {
        return nil
    }

    var binDir: AbsolutePath? {
        return nil
    }

    var swiftCompilerFlags: [String] {
        return []
    }

    var xctestLocation: AbsolutePath? {
        return nil
    }
}

/// Protocol for the manifest loader interface.
public protocol ManifestLoaderProtocol {
    /// Load the manifest for the package at `path`.
    ///
    /// - Parameters:
    ///   - path: The root path of the package.
    ///   - baseURL: The URL the manifest was loaded from.
    ///   - version: The version the manifest is from, if known.
    ///   - revision: The revision the manifest is from, if known.
    ///   - toolsVersion: The version of the tools the manifest supports.
    ///   - kind: The kind of package the manifest is from.
    ///   - fileSystem: If given, the file system to load from (otherwise load from the local file system).
    ///   - diagnostics: The diagnostics engine.
    func load(
        packageIdentity: PackageIdentity2,
        packageKind: PackageReference.Kind,
        at path: AbsolutePath,
        url: String,
        version: Version?,
        revision: String?,
        toolsVersion: ToolsVersion,
        fileSystem: FileSystem?,
        diagnostics: DiagnosticsEngine?,
        on queue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    )

    /// Reset any internal cache held by the manifest loader.
    func resetCache() throws
}

extension ManifestLoaderProtocol {
    /// Load the manifest for the package at `path`.
    ///
    /// - Parameters:
    ///   - path: The root path of the package.
    ///   - baseURL: The URL the manifest was loaded from.
    ///   - version: The version the manifest is from, if known.
    ///   - revision: The revision the manifest is from, if known.
    ///   - toolsVersion: The version of the tools the manifest supports.
    ///   - kind: The kind of package the manifest is from.
    ///   - fileSystem: If given, the file system to load from (otherwise load from the local file system).
    ///   - diagnostics: The diagnostics engine.
    public func load(
        packageIdentity: PackageIdentity2,
        packageKind: PackageReference.Kind,
        at path: AbsolutePath,
        url: String,
        version: Version? = nil,
        revision: String? = nil,
        toolsVersion: ToolsVersion,
        fileSystem: FileSystem? = nil,
        diagnostics: DiagnosticsEngine? = nil,
        on queue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        self.load(
            packageIdentity: packageIdentity,
            packageKind: packageKind,
            at: path,
            url: url,
            version: version,
            revision: revision,
            toolsVersion: toolsVersion,
            fileSystem: fileSystem,
            diagnostics: diagnostics,
            on: queue,
            completion: completion
        )
    }

    public func resetCache() throws {
    }
}

public protocol ManifestLoaderDelegate {
    func willLoad(manifest: AbsolutePath)
    func willParse(manifest: AbsolutePath)
}

/// Utility class for loading manifest files.
///
/// This class is responsible for reading the manifest data and produce a
/// properly formed `PackageModel.Manifest` object. It currently does so by
/// interpreting the manifest source using Swift -- that produces a JSON
/// serialized form of the manifest (as implemented by `PackageDescription`'s
/// `atexit()` handler) which is then deserialized and loaded.
public final class ManifestLoader: ManifestLoaderProtocol {
    private static var _hostTriple = ThreadSafeBox<Triple>()
    private static var _packageDescriptionMinimumDeploymentTarget = ThreadSafeBox<String>()

    private let resources: ManifestResourceProvider
    private let serializedDiagnostics: Bool
    private let isManifestSandboxEnabled: Bool
    private let delegate: ManifestLoaderDelegate?
    private let extraManifestFlags: [String]

    private let databaseCacheDir: AbsolutePath?
    private var databaseCache: PersistentCacheProtocol?
    private let databaseCacheLock = Lock()

    private let useInMemoryCache: Bool
    private let memoryCache = ThreadSafeKeyValueStore<ManifestCacheKey, Manifest>()

    // Cache storage for computed sdk path.
    private var sdkRootCache = ThreadSafeBox<AbsolutePath>()

    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    private let operationQueue: OperationQueue

    public init(
        manifestResources: ManifestResourceProvider,
        serializedDiagnostics: Bool = false,
        isManifestSandboxEnabled: Bool = true,
        cacheDir: AbsolutePath? = nil,
        useInMemoryCache: Bool = true,
        delegate: ManifestLoaderDelegate? = nil,
        extraManifestFlags: [String] = []
    ) {
        self.resources = manifestResources
        self.serializedDiagnostics = serializedDiagnostics
        self.isManifestSandboxEnabled = isManifestSandboxEnabled
        self.delegate = delegate
        self.extraManifestFlags = extraManifestFlags

        self.jsonEncoder = JSONEncoder.makeWithDefaults()
        self.jsonDecoder = JSONDecoder.makeWithDefaults()

        self.useInMemoryCache = useInMemoryCache
        self.databaseCacheDir = cacheDir.map(resolveSymlinks)

        self.operationQueue = OperationQueue()
        self.operationQueue.name = "org.swift.swiftpm.manifest-loader"
        self.operationQueue.maxConcurrentOperationCount = Concurrency.maxOperations
    }

    // FIXME: deprecated before 12/2020, remove once clients migrate
    @available(*, deprecated)
    public convenience init(resources: ManifestResourceProvider, isManifestSandboxEnabled: Bool = true) {
        self.init(manifestResources: resources, isManifestSandboxEnabled: isManifestSandboxEnabled)
    }

    /// Loads a manifest from a package repository using the resources associated with a particular `swiftc` executable.
    ///
    /// - Parameters:
    ///     - packagePath: The absolute path of the package root.
    ///     - swiftCompiler: The absolute path of a `swiftc` executable.
    ///         Its associated resources will be used by the loader.
    ///     - kind: The kind of package the manifest is from.
    public static func loadManifest(
        packageIdentity: PackageIdentity2,
        packageKind: PackageReference.Kind,
        at path: AbsolutePath,
        swiftCompiler: AbsolutePath,
        swiftCompilerFlags: [String],
        on queue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        do {
            let fileSystem = localFileSystem
            let resources = try UserManifestResources(swiftCompiler: swiftCompiler, swiftCompilerFlags: swiftCompilerFlags)
            let loader = ManifestLoader(manifestResources: resources)
            let toolsVersion = try ToolsVersionLoader().load(at: path, fileSystem: fileSystem)
            loader.load(
                packageIdentity: packageIdentity,
                packageKind: packageKind,
                at: path,
                url: path.pathString,
                toolsVersion: toolsVersion,
                fileSystem: fileSystem,
                on: queue,
                completion: completion
            )
        } catch {
            return completion(.failure(error))
        }
    }



    public func load(
        packageIdentity: PackageIdentity2,
        packageKind: PackageReference.Kind,
        at path: AbsolutePath,
        url: String,
        version: Version?,
        revision: String?,
        toolsVersion: ToolsVersion,
        fileSystem: FileSystem? = nil,
        diagnostics: DiagnosticsEngine? = nil,
        on queue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        do {
            let fileSystem = fileSystem ?? localFileSystem
            let manifestPath = try Manifest.path(atPackagePath: path, fileSystem: fileSystem)
            //let packageIdentity = PackageIdentity(url: baseURL)
            let cacheKey = try ManifestCacheKey(packageIdentity: packageIdentity,
                                                manifestPath: path,
                                                toolsVersion: toolsVersion,
                                                env: ProcessEnv.vars,
                                                swiftpmVersion: Versioning.currentVersion.displayString,
                                                fileSystem: fileSystem)

            if self.useInMemoryCache, let manifest = self.memoryCache[cacheKey] {
                // Inform the delegate (backwards compatibility)
                self.delegate?.willLoad(manifest: manifestPath)
                return completion(.success(manifest))
            }

            self.loadFile(packageIdentity: packageIdentity,
                          packageKind: packageKind,
                          at: path,
                          url: url,
                          version: version,
                          revision: revision,
                          toolsVersion: toolsVersion,
                          fileSystem: fileSystem,
                          diagnostics: diagnostics,
                          on: queue) { result in

                // cache positive results
                if self.useInMemoryCache, case .success(let manifest) = result {
                    self.memoryCache[cacheKey] = manifest
                }

                completion(result)
            }
        } catch {
            return completion(.failure(error))
        }
    }

    /// Create a manifest by loading a specific manifest file from the given `path`.
    ///
    /// - Parameters:
    ///   - path: The path to the manifest file (or a package root).
    ///   - baseURL: The URL the manifest was loaded from.
    ///   - version: The version the manifest is from, if known.
    ///   - revision: The revision the manifest is from, if known.
    ///   - kind: The kind of package the manifest is from.
    ///   - fileSystem: If given, the file system to load from (otherwise load from the local file system).
    private func loadFile(
        packageIdentity: PackageIdentity2,
        packageKind: PackageReference.Kind,
        at path: AbsolutePath,
        url: String,
        version: Version?,
        revision: String?,
        toolsVersion: ToolsVersion,
        fileSystem: FileSystem,
        diagnostics: DiagnosticsEngine? = nil,
        on queue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        self.operationQueue.addOperation {
            do {
                // Inform the delegate.
                queue.async {
                    self.delegate?.willLoad(manifest: path)
                }

                // Validate that the file exists.
                guard fileSystem.isFile(path) else {
                    throw PackageModel.Package.Error.noManifest(
                        baseURL: url, version: version?.description)
                }

                // Get the JSON string for the manifest.

                let jsonString = try self.loadJSONString(
                    path: path,
                    toolsVersion: toolsVersion,
                    packageIdentity: packageIdentity,
                    fileSystem: fileSystem,
                    diagnostics: diagnostics
                )

                // Load the manifest from JSON.
                let json = try JSON(string: jsonString)
                var manifestBuilder = ManifestBuilder(
                    toolsVersion: toolsVersion,
                    baseURL: url,
                    fileSystem: fileSystem
                )
                try manifestBuilder.build(v4: json, toolsVersion: toolsVersion)

                // Throw if we encountered any runtime errors.
                guard manifestBuilder.errors.isEmpty else {
                    throw ManifestParseError.runtimeManifestErrors(manifestBuilder.errors)
                }

                // Convert legacy system packages to the current target‐based model.
                var products =  manifestBuilder.products
                var targets = manifestBuilder.targets
                if products.isEmpty, targets.isEmpty,
                    fileSystem.isFile(path.parentDirectory.appending(component: moduleMapFilename)) {
                        products.append(ProductDescription(
                        name: manifestBuilder.name,
                        type: .library(.automatic),
                        targets: [manifestBuilder.name])
                    )
                    targets.append(TargetDescription(
                        name: manifestBuilder.name,
                        path: "",
                        type: .system,
                        pkgConfig: manifestBuilder.pkgConfig,
                        providers: manifestBuilder.providers
                    ))
                }

                let manifest = Manifest(
                    name: manifestBuilder.name,
                    defaultLocalization: manifestBuilder.defaultLocalization,
                    platforms: manifestBuilder.platforms,
                    path: path,
                    url: url,
                    version: version,
                    revision: revision,
                    toolsVersion: toolsVersion,
                    packageKind: packageKind,
                    pkgConfig: manifestBuilder.pkgConfig,
                    providers: manifestBuilder.providers,
                    cLanguageStandard: manifestBuilder.cLanguageStandard,
                    cxxLanguageStandard: manifestBuilder.cxxLanguageStandard,
                    swiftLanguageVersions: manifestBuilder.swiftLanguageVersions,
                    dependencies: manifestBuilder.dependencies,
                    products: products,
                    targets: targets
                )

                try self.validate(manifest, toolsVersion: toolsVersion, diagnostics: diagnostics)

                if let diagnostics = diagnostics, diagnostics.hasErrors {
                    throw Diagnostics.fatalError
                }

                queue.async {
                    completion(.success(manifest))
                }
            } catch {
                queue.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Validate the provided manifest.
    private func validate(_ manifest: Manifest, toolsVersion: ToolsVersion, diagnostics: DiagnosticsEngine?) throws {
        try self.validateTargets(manifest, diagnostics: diagnostics)
        try self.validateProducts(manifest, diagnostics: diagnostics)
        try self.validateDependencies(manifest, toolsVersion: toolsVersion, diagnostics: diagnostics)

        // Checks reserved for tools version 5.2 features
        if toolsVersion >= .v5_2 {
            try self.validateTargetDependencyReferences(manifest, diagnostics: diagnostics)
            try self.validateBinaryTargets(manifest, diagnostics: diagnostics)
        }
    }

    private func validateTargets(_ manifest: Manifest, diagnostics: DiagnosticsEngine?) throws {
        let duplicateTargetNames = manifest.targets.map({ $0.name }).spm_findDuplicates()
        for name in duplicateTargetNames {
            try diagnostics.emit(.duplicateTargetName(targetName: name))
        }
    }

    private func validateProducts(_ manifest: Manifest, diagnostics: DiagnosticsEngine?) throws {
        for product in manifest.products {
            // Check that the product contains targets.
            guard !product.targets.isEmpty else {
                try diagnostics.emit(.emptyProductTargets(productName: product.name))
                continue
            }

            // Check that the product references existing targets.
            for target in product.targets {
                if !manifest.targetMap.keys.contains(target) {
                    try diagnostics.emit(.productTargetNotFound(productName: product.name, targetName: target, validTargets: manifest.targetMap.keys.sorted()))
                }
            }

            // Check that products that reference only binary targets don't define a type.
            let areTargetsBinary = product.targets.allSatisfy { manifest.targetMap[$0]?.type == .binary }
            if areTargetsBinary && product.type != .library(.automatic) {
                try diagnostics.emit(.invalidBinaryProductType(productName: product.name))
            }
        }
    }

    private func validateDependencies(
        _ manifest: Manifest,
        toolsVersion: ToolsVersion,
        diagnostics: DiagnosticsEngine?
    ) throws {
        let dependenciesByIdentity = Dictionary(grouping: manifest.dependencies, by: { dependency in
            //PackageIdentity(url: dependency.url)
            dependency.identity
        })

        let duplicateDependencyIdentities = dependenciesByIdentity
            .lazy
            .filter({ $0.value.count > 1 })
            .map({ $0.key })

        for identity in duplicateDependencyIdentities {
            try diagnostics.emit(.duplicateDependency(dependencyIdentity: identity))
        }

        if toolsVersion >= .v5_2 {
            let duplicateDependencies = try duplicateDependencyIdentities.flatMap{ identifier -> [PackageDependencyDescription] in
                guard let dependency = dependenciesByIdentity[identifier] else {
                    throw InternalError("unknown dependency \(identifier)")
                }
                return dependency
            }
            let duplicateDependencyNames = manifest.dependencies
                .lazy
                .filter({ !duplicateDependencies.contains($0) })
                .map({ $0.name })
                .spm_findDuplicates()

            for name in duplicateDependencyNames {
                try diagnostics.emit(.duplicateDependencyName(dependencyName: name))
            }
        }
    }

    private func validateBinaryTargets(_ manifest: Manifest, diagnostics: DiagnosticsEngine?) throws {
        // Check that binary targets point to the right file type.
        for target in manifest.targets where target.type == .binary {
            guard let location = URL(string: target.url ?? target.path ?? "") else {
                try diagnostics.emit(.invalidBinaryLocation(targetName: target.name))
                continue
            }

            let isRemote = target.url != nil
            let validSchemes = ["https"]
            if isRemote && (location.scheme.map({ !validSchemes.contains($0) }) ?? true) {
                try diagnostics.emit(.invalidBinaryURLScheme(
                    targetName: target.name,
                    validSchemes: validSchemes
                ))
            }

            let validExtensions = isRemote ? ["zip"] : ["xcframework"]
            if !validExtensions.contains(location.pathExtension) {
                try diagnostics.emit(.unsupportedBinaryLocationExtension(
                    targetName: target.name,
                    validExtensions: validExtensions
                ))
            }
        }
    }

    /// Validates that product target dependencies reference an existing package.
    private func validateTargetDependencyReferences(_ manifest: Manifest, diagnostics: DiagnosticsEngine?) throws {
        for target in manifest.targets {
            for targetDependency in target.dependencies {
                switch targetDependency {
                case .target:
                    // If this is a target dependency, we don't need to check anything.
                    break
                case .product(_, let packageName, _):
                    if manifest.packageDependency(referencedBy: targetDependency) == nil {
                        try diagnostics.emit(.unknownTargetPackageDependency(
                            packageName: packageName ?? "unknown package name",
                            targetName: target.name,
                            validPackages: manifest.dependencies.map { $0.name }
                        ))
                    }
                case .byName(let name, _):
                    // Don't diagnose root manifests so we can emit a better diagnostic during package loading.
                    if manifest.packageKind != .root &&
                       !manifest.targetMap.keys.contains(name) &&
                       manifest.packageDependency(referencedBy: targetDependency) == nil
                    {
                        try diagnostics.emit(.unknownTargetDependency(
                            dependency: name,
                            targetName: target.name,
                            validDependencies: manifest.dependencies.map { $0.name }
                        ))
                    }
                }
            }
        }
    }

    /// Load the JSON string for the given manifest.
    private func loadJSONString(
        path manifestPath: AbsolutePath,
        toolsVersion: ToolsVersion,
        packageIdentity: PackageIdentity2,
        fileSystem: FileSystem,
        diagnostics: DiagnosticsEngine? = nil
    ) throws -> String {
        let result: ManifestParseResult

        let cacheKey = try ManifestCacheKey(
            packageIdentity: packageIdentity,
            manifestPath: manifestPath,
            toolsVersion: toolsVersion,
            env: ProcessEnv.vars,
            swiftpmVersion: Versioning.currentVersion.displayString,
            fileSystem: fileSystem
        )

        // Resolve symlinks since we can't use them in sandbox profiles.

        if let cache = try self.createCacheIfNeeded() {
            result = try self.loadManifestFromCache(key: cacheKey, cache: cache)
        } else {
            result = self.parse(
                packageIdentity: packageIdentity,
                manifestPath: cacheKey.manifestPath,
                manifestContents: cacheKey.manifestContents,
                toolsVersion: toolsVersion)
        }

        // Throw now if we weren't able to parse the manifest.
        guard let parsedManifest = result.parsedManifest else {
            let errors = result.errorOutput ?? result.compilerOutput ?? "Unknown error parsing manifest for \(packageIdentity)"
            throw ManifestParseError.invalidManifestFormat(errors, diagnosticFile: result.diagnosticFile)
        }

        // We should not have any fatal error at this point.
        assert(result.errorOutput == nil)

        // We might have some non-fatal output (warnings/notes) from the compiler even when
        // we were able to parse the manifest successfully.
        if let compilerOutput = result.compilerOutput {
            diagnostics?.emit(.warning(ManifestLoadingDiagnostic(output: compilerOutput, diagnosticFile: result.diagnosticFile)))
        }

        return parsedManifest
    }

    fileprivate func loadManifestFromCache(
        key: ManifestCacheKey,
        cache: PersistentCacheProtocol
    ) throws -> ManifestParseResult {
        let keyHash = try key.computeHash()
        let cacheHit = try keyHash.withData {
            try cache.get(key: $0)
        }.flatMap {
            try? self.jsonDecoder.decode(ManifestParseResult.self, from: $0)
        }
        if let result = cacheHit {
            return result
        }

        let result = self.parse(
            packageIdentity: key.packageIdentity,
            manifestPath: key.manifestPath,
            manifestContents: key.manifestContents,
            toolsVersion: key.toolsVersion
        )

        // only cache successfully parsed manifests,
        // this is important for swift-pm development
        if !result.hasErrors {
            try keyHash.withData {
                try cache.put(key: $0, value: self.jsonEncoder.encode(result))
            }
        }

        return result
    }

    fileprivate struct ManifestCacheKey: Hashable {
        let packageIdentity: PackageIdentity2
        let manifestPath: AbsolutePath
        let manifestContents: [UInt8]
        let toolsVersion: ToolsVersion
        let env: [String: String]
        let swiftpmVersion: String

        init (packageIdentity: PackageIdentity2,
              manifestPath: AbsolutePath,
              toolsVersion: ToolsVersion,
              env: [String: String],
              swiftpmVersion: String,
              fileSystem: FileSystem
        ) throws {
            self.packageIdentity = packageIdentity
            self.manifestPath = manifestPath
            self.manifestContents = try fileSystem.readFileContents(manifestPath).contents
            self.toolsVersion = toolsVersion
            self.env = env
            self.swiftpmVersion = swiftpmVersion
        }

        // TODO: is there a way to avoid the dual hashing?
        func hash(into hasher: inout Hasher) {
            hasher.combine(self.packageIdentity)
            hasher.combine(self.manifestContents)
            hasher.combine(self.toolsVersion.description)
            for key in self.env.keys.sorted(by: >) {
                hasher.combine(key)
                hasher.combine(env[key]!) // forced unwrap safe
            }
            hasher.combine(self.swiftpmVersion)
        }

        // TODO: is there a way to avoid the dual hashing?
        func computeHash() throws -> ByteString {
            let stream = BufferedOutputByteStream()
            stream <<< self.packageIdentity
            stream <<< self.manifestContents
            stream <<< self.toolsVersion.description
            for key in self.env.keys.sorted(by: >) {
                stream <<< key <<< env[key]!  // forced unwrap safe
            }
            stream <<< self.swiftpmVersion
            return SHA256().hash(stream.bytes)
        }
    }

    fileprivate struct ManifestParseResult: Codable {
        var hasErrors: Bool {
            return parsedManifest == nil
        }

        /// The path to the diagnostics file (.dia).
        ///
        /// This is only present if serialized diagnostics are enabled.
        var diagnosticFile: AbsolutePath?

        /// The output from compiler, if any.
        ///
        /// This would contain the errors and warnings produced when loading the manifest file.
        var compilerOutput: String?

        /// The parsed manifest in JSON format.
        var parsedManifest: String?

        /// Any non-compiler error that might have occurred during manifest loading.
        ///
        /// For e.g., we could have failed to spawn the process or create temporary file.
        var errorOutput: String? {
            didSet {
                assert(parsedManifest == nil)
            }
        }
    }

    /// Parse the manifest at the given path to JSON.
    fileprivate func parse(
        packageIdentity: PackageIdentity2,
        manifestPath: AbsolutePath,
        manifestContents: [UInt8],
        toolsVersion: ToolsVersion
    ) -> ManifestParseResult {
        /// Helper method for parsing the manifest.
        func _parse(
            path manifestPath: AbsolutePath,
            toolsVersion: ToolsVersion,
            manifestParseResult: inout ManifestParseResult
        ) throws {
            self.delegate?.willParse(manifest: manifestPath)

            // The compiler has special meaning for files with extensions like .ll, .bc etc.
            // Assert that we only try to load files with extension .swift to avoid unexpected loading behavior.
            assert(manifestPath.extension == "swift",
                   "Manifest files must contain .swift suffix in their name, given: \(manifestPath).")

            // For now, we load the manifest by having Swift interpret it directly.
            // Eventually, we should have two loading processes, one that loads only
            // the declarative package specification using the Swift compiler directly
            // and validates it.

            // Compute the path to runtime we need to load.
            let runtimePath = self.runtimePath(for: toolsVersion)

            // FIXME: Workaround for the module cache bug that's been haunting Swift CI
            // <rdar://problem/48443680>
            let moduleCachePath = ProcessEnv.vars["SWIFTPM_MODULECACHE_OVERRIDE"] ?? ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"]

            var cmd: [String] = []
            cmd += [resources.swiftCompiler.pathString]
            cmd += verbosity.ccArgs

            let macOSPackageDescriptionPath: AbsolutePath
            // If we got the binDir that means we could be developing SwiftPM in Xcode
            // which produces a framework for dynamic package products.
            let packageFrameworkPath = runtimePath.appending(component: "PackageFrameworks")
            if resources.binDir != nil, localFileSystem.exists(packageFrameworkPath)  {
                cmd += [
                    "-F", packageFrameworkPath.pathString,
                    "-framework", "PackageDescription",
                    "-Xlinker", "-rpath", "-Xlinker", packageFrameworkPath.pathString,
                ]

                macOSPackageDescriptionPath = packageFrameworkPath.appending(RelativePath("PackageDescription.framework/PackageDescription"))
            } else {
                cmd += [
                    "-L", runtimePath.pathString,
                    "-lPackageDescription",
                ]
#if !os(Windows)
                // -rpath argument is not supported on Windows,
                // so we add runtimePath to PATH when executing the manifest instead
                cmd += ["-Xlinker", "-rpath", "-Xlinker", runtimePath.pathString]
#endif

                // note: this is not correct for all platforms, but we only actually use it on macOS.
                macOSPackageDescriptionPath = runtimePath.appending(RelativePath("libPackageDescription.dylib"))
            }

            // Use the same minimum deployment target as the PackageDescription library (with a fallback of 10.15).
            #if os(macOS)
            let triple = Self._hostTriple.memoize {
                Triple.getHostTriple(usingSwiftCompiler: resources.swiftCompiler)
            }

            let version = try Self._packageDescriptionMinimumDeploymentTarget.memoize {
                (try MinimumDeploymentTarget.computeMinimumDeploymentTarget(of: macOSPackageDescriptionPath))?.versionString ?? "10.15"
            }
            cmd += ["-target", "\(triple.tripleString(forPlatformVersion: version))"]
            #endif

            // Add any extra flags required as indicated by the ManifestLoader.
            cmd += resources.swiftCompilerFlags

            cmd += self.interpreterFlags(for: toolsVersion)
            if let moduleCachePath = moduleCachePath {
                cmd += ["-module-cache-path", moduleCachePath]
            }

            // Add the arguments for emitting serialized diagnostics, if requested.
            if self.serializedDiagnostics, let databaseCacheDir = self.databaseCacheDir {
                let diaDir = databaseCacheDir.appending(component: "ManifestLoading")
                let diagnosticFile = diaDir.appending(component: "\(packageIdentity).dia")
                try localFileSystem.createDirectory(diaDir, recursive: true)
                cmd += ["-Xfrontend", "-serialize-diagnostics-path", "-Xfrontend", diagnosticFile.pathString]
                manifestParseResult.diagnosticFile = diagnosticFile
            }

            cmd += [manifestPath.pathString]

            cmd += self.extraManifestFlags

            try withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
                // Set path to compiled manifest executable.
#if os(Windows)
                let executableSuffix = ".exe"
#else
                let executableSuffix = ""
#endif
                let compiledManifestFile = tmpDir.appending(component: "\(packageIdentity)-manifest\(executableSuffix)")
                cmd += ["-o", compiledManifestFile.pathString]

                // Compile the manifest.
                let compilerResult = try Process.popen(arguments: cmd)
                let compilerOutput = try (compilerResult.utf8Output() + compilerResult.utf8stderrOutput()).spm_chuzzle()
                manifestParseResult.compilerOutput = compilerOutput

                // Return now if there was an error.
                if compilerResult.exitStatus != .terminated(code: 0) {
                    return
                }
                
                // Pass an open file descriptor of a file to which the JSON representation of the manifest will be written.
                let jsonOutputFile = tmpDir.appending(component: "\(packageIdentity)-output.json")
                guard let jsonOutputFileDesc = fopen(jsonOutputFile.pathString, "w") else {
                    throw StringError("couldn't create the manifest's JSON output file")
                }

                cmd = [compiledManifestFile.pathString]
#if os(Windows)
                // NOTE: `_get_osfhandle` returns a non-owning, unsafe,
                // unretained HANDLE.  DO NOT invoke `CloseHandle` on `hFile`.
                let hFile: Int = _get_osfhandle(_fileno(jsonOutputFileDesc))
                cmd += ["-handle", "\(String(hFile, radix: 16))"]
#else
                cmd += ["-fileno", "\(fileno(jsonOutputFileDesc))"]
#endif

              #if os(macOS)
                // If enabled, use sandbox-exec on macOS. This provides some safety against
                // arbitrary code execution when parsing manifest files. We only allow
                // the permissions which are absolutely necessary for manifest parsing.
                if isManifestSandboxEnabled {
                    let cacheDirectories = [
                        self.databaseCacheDir,
                        moduleCachePath.map({ AbsolutePath($0) })
                    ].compactMap({ $0 })
                    let profile = sandboxProfile(toolsVersion: toolsVersion, cacheDirectories: cacheDirectories)
                    cmd = ["/usr/bin/sandbox-exec", "-p", profile] + cmd
                }
              #endif

                // Run the compiled manifest.
                var environment = ProcessEnv.vars
#if os(Windows)
                let windowsPathComponent = runtimePath.pathString.replacingOccurrences(of: "/", with: "\\")
                environment["Path"] = "\(windowsPathComponent);\(environment["Path"] ?? "")"
#endif
                let runResult = try Process.popen(arguments: cmd, environment: environment)
                fclose(jsonOutputFileDesc)
                let runOutput = try (runResult.utf8Output() + runResult.utf8stderrOutput()).spm_chuzzle()
                if let runOutput = runOutput {
                    // Append the runtime output to any compiler output we've received.
                    manifestParseResult.compilerOutput = (manifestParseResult.compilerOutput ?? "") + runOutput
                }

                // Return now if there was an error.
                if runResult.exitStatus != .terminated(code: 0) {
                    manifestParseResult.errorOutput = runOutput
                    return
                }

                // Read the JSON output that was emitted by libPackageDescription.
                guard let jsonOutput = try localFileSystem.readFileContents(jsonOutputFile).validDescription else {
                    throw StringError("the manifest's JSON output has invalid encoding")
                }
                manifestParseResult.parsedManifest = jsonOutput
            }
        }

        var manifestParseResult = ManifestParseResult()
        do {
            if localFileSystem.isFile(manifestPath) {
                try _parse(
                    path: manifestPath,
                    toolsVersion: toolsVersion,
                    manifestParseResult: &manifestParseResult
                )
            } else {
                try withTemporaryFile(suffix: ".swift") { tempFile in
                    try localFileSystem.writeFileContents(tempFile.path, bytes: ByteString(manifestContents))
                    try _parse(
                        path: tempFile.path,
                        toolsVersion: toolsVersion,
                        manifestParseResult: &manifestParseResult
                    )
                }
            }
        } catch {
            assert(manifestParseResult.parsedManifest == nil)
            manifestParseResult.errorOutput = error.localizedDescription
        }

        return manifestParseResult
    }

    /// Returns path to the sdk, if possible.
    private func sdkRoot() -> AbsolutePath? {
        if let sdkRoot = self.sdkRootCache.get() {
            return sdkRoot
        }

        var sdkRootPath: AbsolutePath? = nil
        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
        let foundPath = try? Process.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")
        guard let sdkRoot = foundPath?.spm_chomp(), !sdkRoot.isEmpty else {
            return nil
        }
        let path = AbsolutePath(sdkRoot)
        sdkRootPath = path
        self.sdkRootCache.put(path)
        #endif

        return sdkRootPath
    }

    /// Returns the interpreter flags for a manifest.
    public func interpreterFlags(
        for toolsVersion: ToolsVersion
    ) -> [String] {
        var cmd = [String]()
        let runtimePath = self.runtimePath(for: toolsVersion)
        cmd += ["-swift-version", toolsVersion.swiftLanguageVersion.rawValue]
        cmd += ["-I", runtimePath.pathString]
      #if os(macOS)
        if let sdkRoot = resources.sdkRoot ?? self.sdkRoot() {
            cmd += ["-sdk", sdkRoot.pathString]
        }
      #endif
        cmd += ["-package-description-version", toolsVersion.description]
        return cmd
    }

    /// Returns the runtime path given the manifest version and path to libDir.
    private func runtimePath(for version: ToolsVersion) -> AbsolutePath {
        // Bin dir will be set when developing swiftpm without building all of the runtimes.
        return resources.binDir ?? resources.libDir.appending(version.runtimeSubpath)
    }

    /// Returns path to the manifest database inside the given cache directory.
    private static func manifestCacheDBPath(_ cacheDir: AbsolutePath) -> AbsolutePath {
        return cacheDir.appending(component: "manifest.db")
    }

    func createCacheIfNeeded() throws -> PersistentCacheProtocol? {
        try self.databaseCacheLock.withLock {
            // Return if we have already created the cache.
            if let cache = self.databaseCache {
                return cache
            }
            guard let databaseCacheDir = self.databaseCacheDir else {
                return nil
            }
            try localFileSystem.createDirectory(databaseCacheDir, recursive: true)
            let manifestCacheDBPath = Self.manifestCacheDBPath(databaseCacheDir)
            self.databaseCache = try SQLiteBackedPersistentCache(cacheFilePath: manifestCacheDBPath)
            return self.databaseCache
        }
    }

    public func resetCache() throws {
        self.memoryCache.clear()
        try self.databaseCacheLock.withLock {
            self.databaseCache = nil
            // Also remove the database file from disk.
            guard let manifestCacheDBPath = self.databaseCacheDir.flatMap({ Self.manifestCacheDBPath($0) }) else {
                return
            }
            try localFileSystem.removeFileTree(manifestCacheDBPath)
        }
    }
}

/// Returns the sandbox profile to be used when parsing manifest on macOS.
private func sandboxProfile(toolsVersion: ToolsVersion, cacheDirectories: [AbsolutePath] = []) -> String {
    let stream = BufferedOutputByteStream()
    stream <<< "(version 1)" <<< "\n"
    // Deny everything by default.
    stream <<< "(deny default)" <<< "\n"
    // Import the system sandbox profile.
    stream <<< "(import \"system.sb\")" <<< "\n"
    // Allow reading all files. Even in 5.3 we need to be able to read the PD dylibs.
    stream <<< "(allow file-read*)" <<< "\n"
    // This is needed to launch any processes.
    stream <<< "(allow process*)" <<< "\n"

    // The following accesses are only needed when interpreting the manifest (versus running a compiled version).
    if toolsVersion < .v5_3 {
        // This is required by the Swift compiler.
        stream <<< "(allow sysctl*)" <<< "\n"
        // Allow writing in temporary locations.
        stream <<< "(allow file-write*" <<< "\n"
        for directory in Platform.darwinCacheDirectories() {
            stream <<< ##"    (regex #"^\##(directory.pathString)/org\.llvm\.clang.*")"## <<< "\n"
        }
        for directory in cacheDirectories {
            stream <<< "    (subpath \"\(directory.pathString)\")" <<< "\n"
        }
        stream <<< ")" <<< "\n"
    }

    return stream.bytes.description
}

extension TSCBasic.Diagnostic.Message {
    static func duplicateTargetName(targetName: String) -> Self {
        .error("duplicate target named '\(targetName)'")
    }

    static func emptyProductTargets(productName: String) -> Self {
        .error("product '\(productName)' doesn't reference any targets")
    }

    static func productTargetNotFound(productName: String, targetName: String, validTargets: [String]) -> Self {
        .error("target '\(targetName)' referenced in product '\(productName)' could not be found; valid targets are: '\(validTargets.joined(separator: "', '"))'")
    }

    static func invalidBinaryProductType(productName: String) -> Self {
        .error("invalid type for binary product '\(productName)'; products referencing only binary targets must have a type of 'library'")
    }

    static func duplicateDependency(dependencyIdentity: PackageIdentity2) -> Self {
        .error("duplicate dependency '\(dependencyIdentity)'")
    }

    static func duplicateDependencyName(dependencyName: String) -> Self {
        .error("duplicate dependency named '\(dependencyName)'; consider differentiating them using the 'name' argument")
    }

    static func unknownTargetDependency(dependency: String, targetName: String, validDependencies: [String]) -> Self {
        .error("unknown dependency '\(dependency)' in target '\(targetName)'; valid dependencies are: '\(validDependencies.joined(separator: "', '"))'")
    }

    static func unknownTargetPackageDependency(packageName: String, targetName: String, validPackages: [String]) -> Self {
        .error("unknown package '\(packageName)' in dependencies of target '\(targetName)'; valid packages are: '\(validPackages.joined(separator: "', '"))'")
    }

    static func invalidBinaryLocation(targetName: String) -> Self {
        .error("invalid location for binary target '\(targetName)'")
    }

    static func invalidBinaryURLScheme(targetName: String, validSchemes: [String]) -> Self {
        .error("invalid URL scheme for binary target '\(targetName)'; valid schemes are: '\(validSchemes.joined(separator: "', '"))'")
    }

    static func unsupportedBinaryLocationExtension(targetName: String, validExtensions: [String]) -> Self {
        .error("unsupported extension for binary target '\(targetName)'; valid extensions are: '\(validExtensions.joined(separator: "', '"))'")
    }

    static func invalidLanguageTag(_ languageTag: String) -> Self {
        .error("""
            invalid language tag '\(languageTag)'; the pattern for language tags is groups of latin characters and \
            digits separated by hyphens
            """)
    }
}
