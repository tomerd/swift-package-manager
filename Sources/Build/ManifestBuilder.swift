/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import LLBuildManifest

import Basics
import TSCBasic
import TSCUtility

import PackageModel
import PackageGraph
import SPMBuildCore

@_implementationOnly import SwiftDriver

public class LLBuildManifestBuilder {
    public enum TargetKind {
        case main
        case test

        public var targetName: String {
            switch self {
            case .main: return "main"
            case .test: return "test"
            }
        }
    }

    /// The build plan to work on.
    public let plan: BuildPlan

    public private(set) var manifest: BuildManifest = BuildManifest()

    var buildConfig: String { buildParameters.configuration.dirname }
    var buildParameters: BuildParameters { plan.buildParameters }
    var buildEnvironment: BuildEnvironment { buildParameters.buildEnvironment }

    /// Create a new builder with a build plan.
    public init(_ plan: BuildPlan) {
        self.plan = plan
    }

    // MARK:- Generate Manifest
    /// Generate manifest at the given path.
    public func generateManifest(at path: AbsolutePath) throws {
        manifest.createTarget(TargetKind.main.targetName)
        manifest.createTarget(TargetKind.test.targetName)
        manifest.defaultTarget = TargetKind.main.targetName

        addPackageStructureCommand()
        addBinaryDependencyCommands()
        if buildParameters.useExplicitModuleBuild {
            // Explicit module builds use the integrated driver directly and
            // require that every target's build jobs specify its dependencies explicitly to plan
            // its build.
            // Currently behind:
            // --experimental-explicit-module-build
            try addTargetsToExplicitBuildManifest()
        } else {
            // Create commands for all target descriptions in the plan.
            for (_, description) in plan.targetMap {
                switch description {
                    case .swift(let desc):
                        try self.createSwiftCompileCommand(desc)
                    case .clang(let desc):
                        try self.createClangCompileCommand(desc)
                }
            }
        }

        try self.addTestManifestGenerationCommand()

        // Create command for all products in the plan.
        for (_, description) in plan.productMap {
            try self.createProductCommand(description)
        }

        // Output a dot graph
        if buildParameters.printManifestGraphviz {
            var serializer = DOTManifestSerializer(manifest: manifest)
            serializer.writeDOT(to: &stdoutStream)
            stdoutStream.flush()
        }

        try ManifestWriter().write(manifest, at: path)
    }

    func addNode(_ node: Node, toTarget targetKind: TargetKind) {
        manifest.addNode(node, toTarget: targetKind.targetName)
    }
}

// MARK:- Package Structure

extension LLBuildManifestBuilder {

    fileprivate func addPackageStructureCommand() {
        let inputs = plan.graph.rootPackages.flatMap { package -> [Node] in
            var inputs = package.targets
                .map { $0.sources.root }
                .sorted()
                .map { Node.directoryStructure($0) }

            // FIXME: Need to handle version-specific manifests.
            inputs.append(file: package.path)

            // FIXME: This won't be the location of Package.resolved for multiroot packages.
            inputs.append(file: package.path.appending(component: "Package.resolved"))

            // FIXME: Add config file as an input

            return inputs
        }

        let name = "PackageStructure"
        let output: Node = .virtual(name)

        manifest.addPkgStructureCmd(
            name: name,
            inputs: inputs,
            outputs: [output]
        )
        manifest.addNode(output, toTarget: name)
    }
}

// MARK:- Binary Dependencies

extension LLBuildManifestBuilder {

    // Creates commands for copying all binary artifacts depended on in the plan.
    fileprivate func addBinaryDependencyCommands() {
        let binaryPaths = Set(plan.targetMap.values.flatMap({ $0.libraryBinaryPaths }))
        for binaryPath in binaryPaths {
            let destination = destinationPath(forBinaryAt: binaryPath)
            addCopyCommand(from: binaryPath, to: destination)
        }
    }
}

// MARK:- Resources Bundle

extension LLBuildManifestBuilder {
    /// Adds command for creating the resources bundle of the given target.
    ///
    /// Returns the virtual node that will build the entire bundle.
    fileprivate func createResourcesBundle(
        for target: TargetBuildDescription
    ) -> Node? {
        guard let bundlePath = target.bundlePath else { return nil }

        var outputs: [Node] = []

        let infoPlistDestination = RelativePath("Info.plist")

        // Create a copy command for each resource file.
        for resource in target.target.underlyingTarget.resources {
            let destination = bundlePath.appending(resource.destination)
            let (_, output) = addCopyCommand(from: resource.path, to: destination)
            outputs.append(output)
        }

        // Create a copy command for the Info.plist if a resource with the same name doesn't exist yet.
        if let infoPlistPath = target.resourceBundleInfoPlistPath {
            let destination = bundlePath.appending(infoPlistDestination)
            let (_, output) = addCopyCommand(from: infoPlistPath, to: destination)
            outputs.append(output)
        }

        let cmdName = target.target.getLLBuildResourcesCmdName(config: buildConfig)
        manifest.addPhonyCmd(name: cmdName, inputs: outputs, outputs: [.virtual(cmdName)])

        return .virtual(cmdName)
    }
}

// MARK:- Compile Swift

extension LLBuildManifestBuilder {
    /// Create a llbuild target for a Swift target description.
    private func createSwiftCompileCommand(
        _ target: SwiftTargetBuildDescription
    ) throws {
        // Inputs.
        let inputs = try self.computeSwiftCompileCmdInputs(target)

        // Outputs.
        let objectNodes = target.objects.map(Node.file)
        let moduleNode = Node.file(target.moduleOutputPath)
        let cmdOutputs = objectNodes + [moduleNode]

        if buildParameters.useIntegratedSwiftDriver {
            try self.addSwiftCmdsViaIntegratedDriver(target, inputs: inputs, objectNodes: objectNodes, moduleNode: moduleNode)
        } else if buildParameters.emitSwiftModuleSeparately {
            try self.addSwiftCmdsEmitSwiftModuleSeparately(target, inputs: inputs, objectNodes: objectNodes, moduleNode: moduleNode)
        } else {
            self.addCmdWithBuiltinSwiftTool(target, inputs: inputs, cmdOutputs: cmdOutputs)
        }

        self.addTargetCmd(target, cmdOutputs: cmdOutputs)
        self.addModuleWrapCmd(target)
    }

    private func addSwiftCmdsViaIntegratedDriver(
        _ target: SwiftTargetBuildDescription,
        inputs: [Node],
        objectNodes: [Node],
        moduleNode: Node
    ) throws {
        // Use the integrated Swift driver to compute the set of frontend
        // jobs needed to build this Swift target.
        var commandLine = try target.emitCommandLine();
        commandLine.append("-driver-use-frontend-path")
        commandLine.append(buildParameters.toolchain.swiftCompiler.pathString)
        // FIXME: At some point SwiftPM should provide its own executor for
        // running jobs/launching processes during planning
        let resolver = try ArgsResolver(fileSystem: target.fs)
        let executor = SPMSwiftDriverExecutor(resolver: resolver,
                                              fileSystem: target.fs,
                                              env: ProcessEnv.vars)
        var driver = try Driver(args: commandLine,
                                diagnosticsEngine: plan.diagnostics,
                                fileSystem: target.fs,
                                executor: executor)
        let jobs = try driver.planBuild()
        try addSwiftDriverJobs(for: target, jobs: jobs, inputs: inputs, resolver: resolver,
                               isMainModule: { driver.isExplicitMainModuleJob(job: $0)})
    }

    private func addSwiftDriverJobs(for targetDescription: SwiftTargetBuildDescription,
                                    jobs: [Job], inputs: [Node],
                                    resolver: ArgsResolver,
                                    isMainModule: (Job) -> Bool) throws {
        // Add build jobs to the manifest
        for job in jobs {
            let tool = try resolver.resolve(.path(job.tool))
            let commandLine = try job.commandLine.map{ try resolver.resolve($0) }
            let arguments = [tool] + commandLine

            let jobInputs = try job.inputs.map { try $0.resolveToNode() }
            let jobOutputs = try job.outputs.map { try $0.resolveToNode() }

            // Add target dependencies as inputs to the main module build command.
            //
            // Jobs for a target's intermediate build artifacts, such as PCMs or
            // modules built from a .swiftinterface, do not have a
            // dependency on cross-target build products. If multiple targets share
            // common intermediate dependency modules, such dependencies can lead
            // to cycles in the resulting manifest.
            var manifestNodeInputs : [Node] = []
            if buildParameters.useExplicitModuleBuild && !isMainModule(job) {
                manifestNodeInputs = jobInputs
            } else {
                manifestNodeInputs = (inputs + jobInputs).uniqued()
            }

            guard let firstJobOutput = jobOutputs.first else {
                throw InternalError("unknown first JobOutput")
            }

            let moduleName = targetDescription.target.c99name
            let description = job.description
            if job.kind.isSwiftFrontend {
                manifest.addSwiftFrontendCmd(
                    name: firstJobOutput.name,
                    moduleName: moduleName,
                    description: description,
                    inputs: manifestNodeInputs,
                    outputs: jobOutputs,
                    args: arguments
                )
            } else {
                manifest.addShellCmd(
                    name: firstJobOutput.name,
                    description: description,
                    inputs: manifestNodeInputs,
                    outputs: jobOutputs,
                    args: arguments
                )
            }
        }
    }

    // Building a Swift module in Explicit Module Build mode requires passing all of its module
    // dependencies as explicit arguments to the build command. Thus, building a SwiftPM package
    // with multiple inter-dependent targets thus requires that each target’s build job must
    // have its target dependencies’ modules passed into it as explicit module dependencies.
    // Because none of the targets have been built yet, a given target's dependency scanning
    // action will not be able to discover its target dependencies' modules. Instead, it is
    // SwiftPM's responsibility to communicate to the driver, when planning a given target's
    // build, that this target has dependencies that are other targets, along with a list of
    // future artifacts of such dependencies (.swiftmodule and .pcm files).
    // The driver will then use those artifacts as explicit inputs to its module’s build jobs.
    //
    // Consider an example SwiftPM package with two targets: target B, and target A, where A
    // depends on B:
    // SwiftPM will process targets in a topological order and “bubble-up” each target’s
    // inter-module dependency graph to its dependees. First, SwiftPM will process B, and be
    // able to plan its full build because it does not have any target dependencies. Then the
    // driver is tasked with planning a build for A. SwiftPM will pass as input to the driver
    // the module dependency graph of its target’s dependencies, in this case, just the
    // dependency graph of B. The driver is then responsible for the necessary post-processing
    // to merge the dependency graphs and plan the build for A, using artifacts of B as explicit
    // inputs.
    public func addTargetsToExplicitBuildManifest() throws {
        // Sort the product targets in topological order in order to collect and "bubble up"
        // their respective dependency graphs to the depending targets.
        let nodes: [ResolvedTarget.Dependency] = plan.targetMap.keys.map {
            ResolvedTarget.Dependency.target($0, conditions: [])
        }
        let allPackageDependencies = try topologicalSort(nodes, successors: { $0.dependencies })

        // All modules discovered so far as a part of this package manifest.
        // This includes modules that correspond to the package's own targets, package dependency
        // targets, and modules that are discovered as dependencies of the above in individual
        // dependency scanning actions
        var discoveredModulesMap : SwiftDriver.ModuleInfoMap = [:]

        // Create commands for all target descriptions in the plan.
        for dependency in allPackageDependencies.reversed() {
            guard case .target(let target, _) = dependency else {
                // Product dependency build jobs are added after the fact.
                // Targets that depend on product dependencies will expand the corresponding
                // product into its constituent targets.
                continue
            }
            guard target.underlyingTarget.type != .systemModule,
                  target.underlyingTarget.type != .binary else {
                // Much like non-Swift targets, system modules will consist of a modulemap
                // somewhere in the filesystem, with the path to that module being either
                // manually-specified or computed based on the system module type (apt, brew).
                // Similarly, binary targets will bring in an .xcframework, the contents of
                // which will be exposed via search paths.
                //
                // In both cases, the dependency scanning action in the driver will be automatically
                // be able to detect such targets' modules.
                continue
            }
            guard let description = plan.targetMap[target] else {
                throw InternalError("Expected description for target \(target)")
            }
            switch description {
                case .swift(let desc):
                    try self.createExplicitSwiftTargetCompileCommand(description: desc,
                                                                     discoveredModulesMap: &discoveredModulesMap)
                case .clang(let desc):
                    try self.createClangCompileCommand(desc)
            }
        }
    }

    private func createExplicitSwiftTargetCompileCommand(
        description: SwiftTargetBuildDescription,
        discoveredModulesMap: inout SwiftDriver.ModuleInfoMap
    ) throws {
        // Inputs.
        let inputs = try self.computeSwiftCompileCmdInputs(description)

        // Outputs.
        let objectNodes = description.objects.map(Node.file)
        let moduleNode = Node.file(description.moduleOutputPath)
        let cmdOutputs = objectNodes + [moduleNode]

        // Commands.
        try addExplicitBuildSwiftCmds(description, inputs: inputs,
                                      discoveredModulesMap: &discoveredModulesMap)

        self.addTargetCmd(description, cmdOutputs: cmdOutputs)
        self.addModuleWrapCmd(description)
    }

    private func addExplicitBuildSwiftCmds(
        _ targetDescription: SwiftTargetBuildDescription,
        inputs: [Node],
        discoveredModulesMap: inout SwiftDriver.ModuleInfoMap
    ) throws {
        // Pass the driver its external dependencies (target dependencies)
        var dependencyModulePathMap: SwiftDriver.ExternalTargetModulePathMap = [:]
        // Collect paths for target dependencies of this target (direct and transitive)
        try self.collectTargetDependencyModulePaths(for: targetDescription.target, dependencyModulePathMap: &dependencyModulePathMap)

        // Compute the set of frontend
        // jobs needed to build this Swift target.
        var commandLine = try targetDescription.emitCommandLine();
        commandLine.append("-driver-use-frontend-path")
        commandLine.append(buildParameters.toolchain.swiftCompiler.pathString)
        commandLine.append("-experimental-explicit-module-build")
        let resolver = try ArgsResolver(fileSystem: targetDescription.fs)
        let executor = SPMSwiftDriverExecutor(resolver: resolver,
                                              fileSystem: targetDescription.fs,
                                              env: ProcessEnv.vars)
        var driver = try Driver(args: commandLine, fileSystem: targetDescription.fs,
                                executor: executor,
                                externalBuildArtifacts: (dependencyModulePathMap, discoveredModulesMap))

        let jobs = try driver.planBuild()

        // Save the path to the target's module to be used by its dependents
        // Save the dependency graph of this target to be used by its dependents
        guard let dependencyGraph = driver.interModuleDependencyGraph else {
            throw InternalError("Expected module dependency graph for target: \(targetDescription)")
        }
        try InterModuleDependencyGraph.mergeModules(from: dependencyGraph,
                                                    into: &discoveredModulesMap)

        try addSwiftDriverJobs(for: targetDescription, jobs: jobs, inputs: inputs, resolver: resolver,
                               isMainModule: { driver.isExplicitMainModuleJob(job: $0)})
    }

    /// Collect a map from all target dependencies of the specified target to the build planning artifacts for said dependency,
    /// in the form of a path to a .swiftmodule file and the dependency's InterModuleDependencyGraph.
    private func collectTargetDependencyModulePaths(
        for target: ResolvedTarget,
        dependencyModulePathMap: inout SwiftDriver.ExternalTargetModulePathMap
    ) throws {
        for dependency in target.dependencies {
            switch dependency {
                case .product:
                    // Product dependencies are broken down into the targets that make them up.
                    guard let dependencyProduct = dependency.product else {
                        throw InternalError("unknown dependency product for \(dependency)")
                    }
                    for dependencyProductTarget in dependencyProduct.targets {
                        try self.addTargetDependencyInfo(for: dependencyProductTarget, dependencyModulePathMap: &dependencyModulePathMap)

                    }
                case .target:
                    // Product dependencies are broken down into the targets that make them up.
                    guard let dependencyTarget = dependency.target else {
                        throw InternalError("unknown dependency target for \(dependency)")
                    }
                    try self.addTargetDependencyInfo(for: dependencyTarget, dependencyModulePathMap: &dependencyModulePathMap)
            }
        }
    }

    private func addTargetDependencyInfo(
        for target: ResolvedTarget,
        dependencyModulePathMap: inout SwiftDriver.ExternalTargetModulePathMap
    ) throws {
        guard case .swift(let dependencySwiftTargetDescription) = plan.targetMap[target] else {
            return
        }
        dependencyModulePathMap[ModuleDependencyId.swiftPlaceholder(target.c99name)] =
            dependencySwiftTargetDescription.moduleOutputPath
        try self.collectTargetDependencyModulePaths(for: target, dependencyModulePathMap: &dependencyModulePathMap)
    }

    private func addSwiftCmdsEmitSwiftModuleSeparately(
        _ target: SwiftTargetBuildDescription,
        inputs: [Node],
        objectNodes: [Node],
        moduleNode: Node
    ) throws {
        // FIXME: We need to ingest the emitted dependencies.

        manifest.addShellCmd(
            name: target.moduleOutputPath.pathString,
            description: "Emitting module for \(target.target.name)",
            inputs: inputs,
            outputs: [moduleNode],
            args: target.emitModuleCommandLine()
        )

        let cmdName = target.target.getCommandName(config: buildConfig)
        manifest.addShellCmd(
            name: cmdName,
            description: "Compiling module \(target.target.name)",
            inputs: inputs,
            outputs: objectNodes,
            args: try target.emitObjectsCommandLine()
        )
    }

    private func addCmdWithBuiltinSwiftTool(
        _ target: SwiftTargetBuildDescription,
        inputs: [Node],
        cmdOutputs: [Node]
    ) {
        let isLibrary = target.target.type == .library || target.target.type == .test
        let cmdName = target.target.getCommandName(config: buildConfig)

        manifest.addSwiftCmd(
            name: cmdName,
            inputs: inputs,
            outputs: cmdOutputs,
            executable: buildParameters.toolchain.swiftCompiler,
            moduleName: target.target.c99name,
            moduleOutputPath: target.moduleOutputPath,
            importPath: buildParameters.buildPath,
            tempsPath: target.tempsPath,
            objects: target.objects,
            otherArgs: target.compileArguments(),
            sources: target.sources,
            isLibrary: isLibrary,
            WMO: buildParameters.configuration == .release
        )
    }

    private func computeSwiftCompileCmdInputs(
        _ target: SwiftTargetBuildDescription
    ) throws -> [Node] {
        var inputs = target.sources.map(Node.file)

        // Add resources node as the input to the target. This isn't great because we
        // don't need to block building of a module until its resources are assembled but
        // we don't currently have a good way to express that resources should be built
        // whenever a module is being built.
        if let resourcesNode = createResourcesBundle(for: .swift(target)) {
            inputs.append(resourcesNode)
        }

        func addStaticTargetInputs(_ target: ResolvedTarget) throws {
            // Ignore C Modules.
            if target.underlyingTarget is SystemLibraryTarget { return }
            // Ignore Binary Modules.
            if target.underlyingTarget is BinaryTarget { return }

            // Depend on the binary for executable targets.
            if target.type == .executable {
                // FIXME: Optimize.
                let _product = plan.graph.allProducts.first {
                    $0.type == .executable && $0.executableModule == target
                }
                if let product = _product {
                    guard let planProduct = plan.productMap[product] else {
                        throw InternalError("unknown product \(product)")
                    }
                    inputs.append(file: planProduct.binary)
                }
                return
            }

            switch plan.targetMap[target] {
            case .swift(let target)?:
                inputs.append(file: target.moduleOutputPath)
            case .clang(let target)?:
                for object in target.objects {
                    inputs.append(file: object)
                }
            case nil:
                throw InternalError("unexpected: target \(target) not in target map \(plan.targetMap)")
            }
        }

        for dependency in target.target.dependencies(satisfying: buildEnvironment) {
            switch dependency {
            case .target(let target, _):
                try addStaticTargetInputs(target)

            case .product(let product, _):
                switch product.type {
                case .executable, .library(.dynamic):
                    guard let planProduct = plan.productMap[product] else {
                        throw InternalError("unknown product \(product)")
                    }
                    // Establish a dependency on binary of the product.
                    inputs.append(file: planProduct.binary)

                // For automatic and static libraries, add their targets as static input.
                case .library(.automatic), .library(.static):
                    for target in product.targets {
                        try addStaticTargetInputs(target)
                    }

                case .test:
                    break
                }
            }
        }

        for binaryPath in target.libraryBinaryPaths {
            let path = destinationPath(forBinaryAt: binaryPath)
            if localFileSystem.isDirectory(binaryPath) {
                inputs.append(directory: path)
            } else {
                inputs.append(file: path)
            }
        }

        return inputs
    }

    /// Adds a top-level phony command that builds the entire target.
    private func addTargetCmd(_ target: SwiftTargetBuildDescription, cmdOutputs: [Node]) {
        // Create a phony node to represent the entire target.
        let targetName = target.target.getLLBuildTargetName(config: buildConfig)
        let targetOutput: Node = .virtual(targetName)

        manifest.addNode(targetOutput, toTarget: targetName)
        manifest.addPhonyCmd(
            name: targetOutput.name,
            inputs: cmdOutputs,
            outputs: [targetOutput]
        )
        if plan.graph.isInRootPackages(target.target) {
            if !target.isTestTarget {
                addNode(targetOutput, toTarget: .main)
            }
            addNode(targetOutput, toTarget: .test)
        }
    }

    private func addModuleWrapCmd(_ target: SwiftTargetBuildDescription) {
        // Add commands to perform the module wrapping Swift modules when debugging statergy is `modulewrap`.
        guard buildParameters.debuggingStrategy == .modulewrap else { return }
        var moduleWrapArgs = [
            target.buildParameters.toolchain.swiftCompiler.pathString,
            "-modulewrap", target.moduleOutputPath.pathString,
            "-o", target.wrappedModuleOutputPath.pathString
        ]
        moduleWrapArgs += buildParameters.targetTripleArgs(for: target.target)
        manifest.addShellCmd(
            name: target.wrappedModuleOutputPath.pathString,
            description: "Wrapping AST for \(target.target.name) for debugging",
            inputs: [.file(target.moduleOutputPath)],
            outputs: [.file(target.wrappedModuleOutputPath)],
            args: moduleWrapArgs)
    }
}

// MARK:- Compile C-family

extension LLBuildManifestBuilder {
    /// Create a llbuild target for a Clang target description.
    private func createClangCompileCommand(
        _ target: ClangTargetBuildDescription
    ) throws {
        let standards = [
            (target.clangTarget.cxxLanguageStandard, SupportedLanguageExtension.cppExtensions),
            (target.clangTarget.cLanguageStandard, SupportedLanguageExtension.cExtensions),
        ]

        var inputs: [Node] = []

        // Add resources node as the input to the target. This isn't great because we
        // don't need to block building of a module until its resources are assembled but
        // we don't currently have a good way to express that resources should be built
        // whenever a module is being built.
        if let resourcesNode = createResourcesBundle(for: .clang(target)) {
            inputs.append(resourcesNode)
        }

        func addStaticTargetInputs(_ target: ResolvedTarget) {
            if case .swift(let desc)? = plan.targetMap[target], target.type == .library {
                inputs.append(file: desc.moduleOutputPath)
            }
        }

        for dependency in target.target.dependencies(satisfying: buildEnvironment) {
            switch dependency {
            case .target(let target, _):
                addStaticTargetInputs(target)

            case .product(let product, _):
                switch product.type {
                case .executable, .library(.dynamic):
                    guard let planProduct = plan.productMap[product] else {
                        throw InternalError("unknown product \(product)")
                    }
                    // Establish a dependency on binary of the product.
                    let binary = planProduct.binary
                    inputs.append(file: binary)

                case .library(.automatic), .library(.static):
                    for target in product.targets {
                        addStaticTargetInputs(target)
                    }
                case .test:
                    break
                }
            }
        }

        for binaryPath in target.libraryBinaryPaths {
            let path = destinationPath(forBinaryAt: binaryPath)
            if localFileSystem.isDirectory(binaryPath) {
                inputs.append(directory: path)
            } else {
                inputs.append(file: path)
            }
        }

        var objectFileNodes: [Node] = []

        for path in target.compilePaths() {
            var args = target.basicArguments()
            args += ["-MD", "-MT", "dependencies", "-MF", path.deps.pathString]

            // Add language standard flag if needed.
            if let ext = path.source.extension {
                for (standard, validExtensions) in standards {
                    if let languageStandard = standard, validExtensions.contains(ext) {
                        args += ["-std=\(languageStandard)"]
                    }
                }
            }

            args += ["-c", path.source.pathString, "-o", path.object.pathString]

            let clangCompiler = try buildParameters.toolchain.getClangCompiler().pathString
            args.insert(clangCompiler, at: 0)

            let objectFileNode: Node = .file(path.object)
            objectFileNodes.append(objectFileNode)

            manifest.addClangCmd(
                name: path.object.pathString,
                description: "Compiling \(target.target.name) \(path.filename)",
                inputs: inputs + [.file(path.source)],
                outputs: [objectFileNode],
                args: args,
                deps: path.deps.pathString
            )
        }

        // Create a phony node to represent the entire target.
        let targetName = target.target.getLLBuildTargetName(config: buildConfig)
        let output: Node = .virtual(targetName)

        manifest.addNode(output, toTarget: targetName)
        manifest.addPhonyCmd(
            name: output.name,
            inputs: objectFileNodes,
            outputs: [output]
        )

        if plan.graph.isInRootPackages(target.target) {
            if !target.isTestTarget {
                addNode(output, toTarget: .main)
            }
            addNode(output, toTarget: .test)
        }
    }
}

// MARK:- Test File Generation

extension LLBuildManifestBuilder {
    fileprivate func addTestManifestGenerationCommand() throws {
        for target in plan.targets {
            guard case .swift(let target) = target,
                target.isTestTarget,
                target.testDiscoveryTarget else { continue }

            let testDiscoveryTarget = target

            let testTargets = testDiscoveryTarget.target.dependencies
                .compactMap{ $0.target }.compactMap{ plan.targetMap[$0] }
            let objectFiles = testTargets.flatMap{ $0.objects }.sorted().map(Node.file)
            let outputs = testDiscoveryTarget.target.sources.paths

            guard let mainOutput = (outputs.first{ $0.basename == "main.swift" }) else {
                throw InternalError("output main.swift not found")
            }
            let cmdName = mainOutput.pathString
            manifest.addTestDiscoveryCmd(
                name: cmdName,
                inputs: objectFiles,
                outputs: outputs.map(Node.file)
            )
        }
    }
}

// MARK:- Product Command

extension LLBuildManifestBuilder {
    private func createProductCommand(_ buildProduct: ProductBuildDescription) throws {
        let cmdName = try buildProduct.product.getCommandName(config: buildConfig)

        // Create archive tool for static library and shell tool for rest of the products.
        if buildProduct.product.type == .library(.static) {
            manifest.addArchiveCmd(
                name: cmdName,
                inputs: buildProduct.objects.map(Node.file),
                outputs: [.file(buildProduct.binary)]
            )
        } else {
            let inputs = buildProduct.objects + buildProduct.dylibs.map({ $0.binary })

            manifest.addShellCmd(
                name: cmdName,
                description: "Linking \(buildProduct.binary.prettyPath())",
                inputs: inputs.map(Node.file),
                outputs: [.file(buildProduct.binary)],
                args: try buildProduct.linkArguments()
            )
        }

        // Create a phony node to represent the entire target.
        let targetName = try buildProduct.product.getLLBuildTargetName(config: buildConfig)
        let output: Node = .virtual(targetName)

        manifest.addNode(output, toTarget: targetName)
        manifest.addPhonyCmd(
            name: output.name,
            inputs: [.file(buildProduct.binary)],
            outputs: [output]
        )

        if plan.graph.reachableProducts.contains(buildProduct.product) {
            if buildProduct.product.type != .test {
                addNode(output, toTarget: .main)
            }
            addNode(output, toTarget: .test)
        }
    }
}

extension ResolvedTarget {
    public func getCommandName(config: String) -> String {
       return "C." + getLLBuildTargetName(config: config)
    }

    public func getLLBuildTargetName(config: String) -> String {
        return "\(name)-\(config).module"
    }

    public func getLLBuildResourcesCmdName(config: String) -> String {
        return "\(name)-\(config).module-resources"
    }
}

extension ResolvedProduct {
    public func getLLBuildTargetName(config: String) throws -> String {
        switch type {
        case .library(.dynamic):
            return "\(name)-\(config).dylib"
        case .test:
            return "\(name)-\(config).test"
        case .library(.static):
            return "\(name)-\(config).a"
        case .library(.automatic):
            throw InternalError("automatic library not supported")
        case .executable:
            return "\(name)-\(config).exe"
        }
    }

    public func getCommandName(config: String) throws -> String {
        return try "C." + self.getLLBuildTargetName(config: config)
    }
}

// MARK:- Helper

extension LLBuildManifestBuilder {
    @discardableResult
    fileprivate func addCopyCommand(
        from source: AbsolutePath,
        to destination: AbsolutePath
    ) -> (inputNode: Node, outputNode: Node) {
        let isDirectory = localFileSystem.isDirectory(source)
        let nodeType = isDirectory ? Node.directory : Node.file
        let inputNode = nodeType(source)
        let outputNode = nodeType(destination)
        manifest.addCopyCmd(name: destination.pathString, inputs: [inputNode], outputs: [outputNode])
        return (inputNode, outputNode)
    }

    fileprivate func destinationPath(forBinaryAt path: AbsolutePath) -> AbsolutePath {
        plan.buildParameters.buildPath.appending(component: path.basename)
    }
}

extension TypedVirtualPath {
    /// Resolve a typed virtual path provided by the Swift driver to
    /// a node in the build graph.
    func resolveToNode() throws -> Node {
        if let absolutePath = file.absolutePath {
            return Node.file(absolutePath)
        } else if let relativePath = file.relativePath {
            guard let workingDirectory = localFileSystem.currentWorkingDirectory else {
                throw InternalError("unknown working directory")
            }
            return Node.file(workingDirectory.appending(relativePath))
        } else if let temporaryFileName = file.temporaryFileName {
            return Node.virtual(temporaryFileName.pathString)
        } else {
            throw InternalError("Cannot resolve VirtualPath: \(file)")
        }
    }
}

extension Sequence where Element: Hashable {
    /// Unique the elements in a sequence.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
