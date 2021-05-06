/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import ArgumentParser
import Basics
import TSCBasic
import SPMBuildCore
import Build
import PackageModel
import PackageLoading
import PackageGraph
import SourceControl
import TSCUtility
import Xcodeproj
import XCBuildSupport
import Workspace
import Foundation

/// swift-package tool namespace
public struct SwiftPackageTool: ParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "package",
        _superCommandName: "swift",
        abstract: "Perform operations on Swift packages",
        discussion: "SEE ALSO: swift build, swift run, swift test",
        version: SwiftVersion.currentVersion.completeDisplayString,
        subcommands: [
            Clean.self,
            PurgeCache.self,
            Reset.self,
            Update.self,
            Describe.self,
            Init.self,
            Create.self,
            Format.self,
            
            APIDiff.self,
            DumpSymbolGraph.self,
            DumpPIF.self,
            DumpPackage.self,
            
            Edit.self,
            Unedit.self,
            
            Config.self,
            Resolve.self,
            Fetch.self,
            
            ShowDependencies.self,
            ToolsVersionCommand.self,
            GenerateXcodeProject.self,
            ComputeChecksum.self,
            ArchiveSource.self,
            CompletionTool.self,
        ],
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    var swiftOptions: SwiftToolOptions

    public init() {}

    public static var _errorLabel: String { "error" }
}

extension DescribeMode: ExpressibleByArgument {}
extension InitPackage.PackageType: ExpressibleByArgument {}
extension ShowDependenciesMode: ExpressibleByArgument {}

extension SwiftPackageTool {
    struct Clean: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete build artifacts")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().clean(with: swiftTool.diagnostics)
        }
    }

    struct PurgeCache: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Purge the global repository cache.")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().purgeCache(with: swiftTool.diagnostics)
        }
    }
    
    struct Reset: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset the complete cache/build directory")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.getActiveWorkspace().reset(with: swiftTool.diagnostics)
        }
    }
    
    struct Update: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update package dependencies")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Flag(name: [.long, .customShort("n")],
              help: "Display the list of dependencies that can be updated")
        var dryRun: Bool = false
        
        @Argument(help: "The packages to update")
        var packages: [String] = []

        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            
            let changes = try workspace.updateDependencies(
                root: swiftTool.getWorkspaceRoot(),
                packages: packages,
                diagnostics: swiftTool.diagnostics,
                dryRun: dryRun
            )

            // try to load the graph which will emit any errors
            if !swiftTool.diagnostics.hasErrors {
                _ = try workspace.loadPackageGraph(
                    rootInput: swiftTool.getWorkspaceRoot(),
                    diagnostics: swiftTool.diagnostics
                )
            }

            if let pinsStore = swiftTool.diagnostics.wrap({ try workspace.pinsStore.load() }), let changes = changes, dryRun {
                logPackageChanges(changes: changes, pins: pinsStore)
            }

            if !dryRun {
                // Throw if there were errors when loading the graph.
                // The actual errors will be printed before exiting.
                guard !swiftTool.diagnostics.hasErrors else {
                    throw ExitCode.failure
                }
            }
        }
    }
    
    struct Describe: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Describe the current package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
                
        @Option(help: "json | text")
        var type: DescribeMode = .text

        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()

            let rootManifests = try temp_await {
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.diagnostics, completion: $0)
            }
            guard let rootManifest = rootManifests.values.first else {
                throw StringError("invalid manifests at \(root.packages)")
            }

            let builder = PackageBuilder(
                identity: .plain(rootManifest.name),
                manifest: rootManifest,
                productFilter: .everything,
                path: try swiftTool.getPackageRoot(),
                xcTestMinimumDeploymentTargets: MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
                diagnostics: swiftTool.diagnostics
            )
            let package = try builder.construct()
            describe(package, in: type, on: stdoutStream)
        }
    }
    
    struct Init: SwiftCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Initialize a new package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(name: .customLong("type"), help: "Package type: empty | library | executable | system-module | manifest")
        var packageType: InitPackage.PackageType = .library
        
        @Option(help: "Create Package from template")
        var template: String?
        
        @Option(name: .customLong("name"), help: "Provide custom package name")
        var packageName: String?
        
        func run(_ swiftTool: SwiftTool) throws {
            guard let configPath = try swiftTool.getConfigPath() else {
                throw InternalError("error")
            }
            try makePackage(
                filesystem: localFileSystem,
                configPath: configPath,
                packageName: packageName,
                mode: .initialize,
                packageType: packageType,
                packageTemplate: template            )
        }
    }

    struct Create: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(name: .customLong("type"))
        var packageType: InitPackage.PackageType = .executable
        
        @Option(help: "Create Package from template")
        var template: String?
        
        @Argument(help: "Package name")
        var packageName: String

        func run(_ swiftTool: SwiftTool) throws {
            guard let configPath = try swiftTool.getConfigPath() else {
                throw InternalError("error")
            }
            try makePackage(
                filesystem: localFileSystem,
                configPath: configPath,
                packageName: packageName,
                mode: .create,
                packageType: packageType,
                packageTemplate: template
            )
        }
    }
    
    struct Format: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "_format")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(parsing: .unconditionalRemaining,
                  help: "Pass flag through to the swift-format tool")
        var swiftFormatFlags: [String] = []
        
        func run(_ swiftTool: SwiftTool) throws {
            // Look for swift-format binary.
            // FIXME: This should be moved to user toolchain.
            let swiftFormatInEnv = lookupExecutablePath(filename: ProcessEnv.vars["SWIFT_FORMAT"])
            guard let swiftFormat = swiftFormatInEnv ?? Process.findExecutable("swift-format") else {
                print("error: Could not find swift-format in PATH or SWIFT_FORMAT")
                throw Diagnostics.fatalError
            }

            // Get the root package.
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()
            let rootManifests = try temp_await {
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.diagnostics, completion: $0)
            }
            guard let rootManifest = rootManifests.values.first else {
                throw StringError("invalid manifests at \(root.packages)")
            }

            let builder = PackageBuilder(
                identity: .plain(rootManifest.name),
                manifest: rootManifest,
                productFilter: .everything,
                path: try swiftTool.getPackageRoot(),
                xcTestMinimumDeploymentTargets: [:], // Minimum deployment target does not matter for this operation.
                diagnostics: swiftTool.diagnostics
            )
            let package = try builder.construct()

            // Use the user provided flags or default to formatting mode.
            let formatOptions = swiftFormatFlags.isEmpty
                ? ["--mode", "format", "--in-place"]
                : swiftFormatFlags

            // Process each target in the root package.
            for target in package.targets {
                for file in target.sources.paths {
                    // Only process Swift sources.
                    guard let ext = file.extension, ext == SupportedLanguageExtension.swift.rawValue else {
                        continue
                    }

                    let args = [swiftFormat.pathString] + formatOptions + [file.pathString]
                    print("Running:", args.map{ $0.spm_shellEscaped() }.joined(separator: " "))

                    let result = try Process.popen(arguments: args)
                    let output = try (result.utf8Output() + result.utf8stderrOutput())

                    if result.exitStatus != .terminated(code: 0) {
                        print("Non-zero exit", result.exitStatus)
                    }
                    if !output.isEmpty {
                        print(output)
                    }
                }
            }
        }
    }
    
    struct APIDiff: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "experimental-api-diff")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Argument(help: "The baseline treeish to compare to (e.g. a commit hash, branch name, tag, etc.)")
        var treeish: String

        func run(_ swiftTool: SwiftTool) throws {
            let apiDigesterPath = try swiftTool.getToolchain().getSwiftAPIDigester()
            let apiDigesterTool = SwiftAPIDigester(tool: apiDigesterPath)

            // Build the current package.
            //
            // We turn build manifest caching off because we need the build plan.
            let buildOp = try swiftTool.createBuildOperation(cacheBuildManifest: false)
            try buildOp.build()

            // Dump JSON for the baseline package.
            let workspace = try swiftTool.getActiveWorkspace()
            let baselineDumper = try APIDigesterBaselineDumper(
                baselineTreeish: treeish,
                packageRoot: swiftTool.getPackageRoot(),
                buildParameters: buildOp.buildParameters,
                manifestLoader: workspace.manifestLoader,
                repositoryManager: workspace.repositoryManager,
                apiDigesterTool: apiDigesterTool,
                diags: swiftTool.diagnostics
            )
            let baselineSDKJSON = try baselineDumper.dumpBaselineSDKJSON()

            // Run the diagnose tool which will print the diff.
            try apiDigesterTool.diagnoseSDK(
                baselineSDKJSON: baselineSDKJSON,
                apiToolArgs: buildOp.buildPlan!.createAPIToolCommonArgs(includeLibrarySearchPaths: false),
                modules: try buildOp.getPackageGraph().apiDigesterModules
            )
        }
    }
    
    struct DumpSymbolGraph: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dump Symbol Graph")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            let symbolGraphExtract = try SymbolGraphExtract(
                tool: swiftTool.getToolchain().getSymbolGraphExtract())

            // Build the current package.
            //
            // We turn build manifest caching off because we need the build plan.
            let buildOp = try swiftTool.createBuildOperation(cacheBuildManifest: false)
            try buildOp.build()

            try symbolGraphExtract.dumpSymbolGraph(
                buildPlan: buildOp.buildPlan!
            )
        }
    }
    
    struct DumpPackage: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print parsed Package.swift as JSON")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            let root = try swiftTool.getWorkspaceRoot()

            let rootManifests = try temp_await {
                workspace.loadRootManifests(packages: root.packages, diagnostics: swiftTool.diagnostics, completion: $0)
            }
            guard let rootManifest = rootManifests.values.first else {
                throw StringError("invalid manifests at \(root.packages)")
            }

            let encoder = JSONEncoder.makeWithDefaults()
            encoder.userInfo[Manifest.dumpPackageKey] = true

            let jsonData = try encoder.encode(rootManifest)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            print(jsonString)
        }
    }
    
    struct DumpPIF: SwiftCommand {
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Flag(help: "Preserve the internal structure of PIF")
        var preserveStructure: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            let graph = try swiftTool.loadPackageGraph(createMultipleTestProducts: true)
            let parameters = try PIFBuilderParameters(swiftTool.buildParameters())
            let builder = PIFBuilder(graph: graph, parameters: parameters, diagnostics: swiftTool.diagnostics)
            let pif = try builder.generatePIF(preservePIFModelStructure: preserveStructure)
            print(pif)
        }
    }
    
    struct Edit: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put a package in editable mode")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Option(help: "The revision to edit", transform: { Revision(identifier: $0) })
        var revision: Revision?
        
        @Option(name: .customLong("branch"), help: "The branch to create")
        var checkoutBranch: String?
        
        @Option(help: "Create or use the checkout at this path")
        var path: AbsolutePath?
        
        @Argument(help: "The name of the package to edit")
        var packageName: String

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.resolve()
            let workspace = try swiftTool.getActiveWorkspace()

            // Put the dependency in edit mode.
            workspace.edit(
                packageName: packageName,
                path: path,
                revision: revision,
                checkoutBranch: checkoutBranch,
                diagnostics: swiftTool.diagnostics)
        }
    }

    struct Unedit: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a package from editable mode")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Flag(name: .customLong("force"),
              help: "Unedit the package even if it has uncommited and unpushed changes")
        var shouldForceRemove: Bool = false
        
        @Argument(help: "The name of the package to unedit")
        var packageName: String

        func run(_ swiftTool: SwiftTool) throws {
            try swiftTool.resolve()
            let workspace = try swiftTool.getActiveWorkspace()

            try workspace.unedit(
                packageName: packageName,
                forceRemove: shouldForceRemove,
                root: swiftTool.getWorkspaceRoot(),
                diagnostics: swiftTool.diagnostics
            )
        }
    }
    
    struct ShowDependencies: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the resolved dependency graph")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "text | dot | json | flatlist")
        var format: ShowDependenciesMode = .text

        func run(_ swiftTool: SwiftTool) throws {
            let graph = try swiftTool.loadPackageGraph()
            dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: format)
        }
    }
    
    struct ToolsVersionCommand: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "tools-version",
            abstract: "Manipulate tools version of the current package")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "text | dot | json | flatlist")
        var format: ShowDependenciesMode = .text

        @Flag(help: "Set tools version of package to the current tools version in use")
        var setCurrent: Bool = false
        
        @Option(help: "Set tools version of package to the given value")
        var set: String?
        
        enum ToolsVersionMode {
            case display
            case set(String)
            case setCurrent
        }
        
        var toolsVersionMode: ToolsVersionMode {
            // TODO: enforce exclusivity
            if let set = set {
                return .set(set)
            } else if setCurrent {
                return .setCurrent
            } else {
                return .display
            }
        }

        func run(_ swiftTool: SwiftTool) throws {
            let pkg = try swiftTool.getPackageRoot()

            switch toolsVersionMode {
            case .display:
                let toolsVersionLoader = ToolsVersionLoader()
                let version = try toolsVersionLoader.load(at: pkg, fileSystem: localFileSystem)
                print("\(version)")

            case .set(let value):
                guard let toolsVersion = ToolsVersion(string: value) else {
                    // FIXME: Probably lift this error defination to ToolsVersion.
                    throw ToolsVersionLoader.Error.malformedToolsVersionSpecification(.versionSpecifier(.isMisspelt(value)))
                }
                try writeToolsVersion(at: pkg, version: toolsVersion, fs: localFileSystem)

            case .setCurrent:
                // Write the tools version with current version but with patch set to zero.
                // We do this to avoid adding unnecessary constraints to patch versions, if
                // the package really needs it, they can do it using --set option.
                try writeToolsVersion(
                    at: pkg, version: ToolsVersion.currentToolsVersion.zeroedPatch, fs: localFileSystem)
            }
        }
    }
    
    struct ComputeChecksum: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compute the checksum for a binary artifact.")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(help: "The absolute or relative path to the binary artifact")
        var path: AbsolutePath
        
        func run(_ swiftTool: SwiftTool) throws {
            let workspace = try swiftTool.getActiveWorkspace()
            let checksum = workspace.checksum(
                forBinaryArtifactAt: path,
                diagnostics: swiftTool.diagnostics
            )

            guard !swiftTool.diagnostics.hasErrors else {
                throw ExitCode.failure
            }

            stdoutStream <<< checksum <<< "\n"
            stdoutStream.flush()
        }
    }

    struct ArchiveSource: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "archive-source",
            abstract: "Create a source archive for the package"
        )

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Option(
            name: [.short, .long],
            help: "The absolute or relative path for the generated source archive"
        )
        var output: AbsolutePath?

        func run(_ swiftTool: SwiftTool) throws {
            let packageRoot = try swiftOptions.packagePath ?? swiftTool.getPackageRoot()
            let repository = GitRepository(path: packageRoot)

            let destination: AbsolutePath
            if let output = output {
                destination = output
            } else {
                let graph = try swiftTool.loadPackageGraph()
                let packageName = graph.rootPackages[0].manifestName // TODO: use identity instead?
                destination = packageRoot.appending(component: "\(packageName).zip")
            }

            try repository.archive(to: destination)

            if destination.contains(packageRoot) {
                let relativePath = destination.relative(to: packageRoot)
                stdoutStream <<< "Created \(relativePath.pathString)" <<< "\n"
            } else {
                stdoutStream <<< "Created \(destination.pathString)" <<< "\n"
            }

            stdoutStream.flush()
        }
    }
}

extension SwiftPackageTool {
    struct GenerateXcodeProject: SwiftCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate-xcodeproj",
            abstract: "Generates an Xcode project. This command will be deprecated soon.")

        struct Options: ParsableArguments {
            @Option(help: "Path to xcconfig file", completion: .file())
            var xcconfigOverrides: AbsolutePath?
            
            @Option(name: .customLong("output"),
                    help: "Path where the Xcode project should be generated")
            var outputPath: AbsolutePath?
            
            @Flag(name: .customLong("legacy-scheme-generator"),
                  help: "Use the legacy scheme generator")
            var useLegacySchemeGenerator: Bool = false
            
            @Flag(name: .customLong("watch"),
                  help: "Watch for changes to the Package manifest to regenerate the Xcode project")
            var enableAutogeneration: Bool = false
            
            @Flag(help: "Do not add file references for extra files to the generated Xcode project")
            var skipExtraFiles: Bool = false
        }

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @OptionGroup()
        var options: Options
        
        func xcodeprojOptions() -> XcodeprojOptions {
            XcodeprojOptions(
                flags: swiftOptions.buildFlags,
                xcconfigOverrides: options.xcconfigOverrides,
                isCodeCoverageEnabled: swiftOptions.shouldEnableCodeCoverage,
                useLegacySchemeGenerator: options.useLegacySchemeGenerator,
                enableAutogeneration: options.enableAutogeneration,
                addExtraFiles: !options.skipExtraFiles)
        }

        func run(_ swiftTool: SwiftTool) throws {
            swiftTool.diagnostics.emit(.warning("Xcode can open and build Swift Packages directly. 'generate-xcodeproj' is no longer needed and will be deprecated soon."))

            let graph = try swiftTool.loadPackageGraph()

            let projectName: String
            let dstdir: AbsolutePath

            switch options.outputPath {
            case let outpath? where outpath.suffix == ".xcodeproj":
                // if user specified path ending with .xcodeproj, use that
                projectName = String(outpath.basename.dropLast(10))
                dstdir = outpath.parentDirectory
            case let outpath?:
                dstdir = outpath
                projectName = graph.rootPackages[0].manifestName // TODO: use identity instead?
            case _:
                dstdir = try swiftTool.getPackageRoot()
                projectName = graph.rootPackages[0].manifestName // TODO: use identity instead?
            }
            let xcodeprojPath = Xcodeproj.buildXcodeprojPath(outputDir: dstdir, projectName: projectName)

            var genOptions = xcodeprojOptions()
            genOptions.manifestLoader = try swiftTool.getManifestLoader()

            try Xcodeproj.generate(
                projectName: projectName,
                xcodeprojPath: xcodeprojPath,
                graph: graph,
                options: genOptions,
                diagnostics: swiftTool.diagnostics
            )

            print("generated:", xcodeprojPath.prettyPath(cwd: swiftTool.originalWorkingDirectory))

            // Run the file watcher if requested.
            if options.enableAutogeneration {
                try WatchmanHelper(
                    diagnostics: swiftTool.diagnostics,
                    watchmanScriptsDir: swiftTool.buildPath.appending(component: "watchman"),
                    packageRoot: swiftTool.packageRoot!
                ).runXcodeprojWatcher(xcodeprojOptions())
            }
        }
    }
}

extension SwiftPackageTool {
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manipulate configuration of the package",
            subcommands: [SetMirror.self, UnsetMirror.self, GetMirror.self])
    }
}

extension SwiftPackageTool.Config {
    struct SetMirror: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a mirror for a dependency")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "The package dependency url")
        var packageURL: String?
        
        @Option(help: "The original url")
        var originalURL: String?
        
        @Option(help: "The mirror url")
        var mirrorURL: String
        
        func run(_ swiftTool: SwiftTool) throws {
            let config = try swiftTool.getSwiftPMConfig()

            if packageURL != nil {
                swiftTool.diagnostics.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalURL = packageURL ?? originalURL else {
                swiftTool.diagnostics.emit(.missingRequiredArg("--original-url"))
                throw ExitCode.failure
            }

            config.mirrors.set(mirrorURL: mirrorURL, forURL: originalURL)
            try config.saveState()
        }
    }

    struct UnsetMirror: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove an existing mirror")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "The package dependency url")
        var packageURL: String?
        
        @Option(help: "The original url")
        var originalURL: String?
        
        @Option(help: "The mirror url")
        var mirrorURL: String?
        
        func run(_ swiftTool: SwiftTool) throws {
            let config = try swiftTool.getSwiftPMConfig()

            if packageURL != nil {
                swiftTool.diagnostics.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalOrMirrorURL = packageURL ?? originalURL ?? mirrorURL else {
                swiftTool.diagnostics.emit(.missingRequiredArg("--original-url or --mirror-url"))
                throw ExitCode.failure
            }

            try config.mirrors.unset(originalOrMirrorURL: originalOrMirrorURL)
            try config.saveState()
        }
    }

    struct GetMirror: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print mirror configuration for the given package dependency")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Option(help: "The package dependency url")
        var packageURL: String?
        
        @Option(help: "The original url")
        var originalURL: String?

        func run(_ swiftTool: SwiftTool) throws {
            let config = try swiftTool.getSwiftPMConfig()

            if packageURL != nil {
                swiftTool.diagnostics.emit(
                    warning: "'--package-url' option is deprecated; use '--original-url' instead")
            }

            guard let originalURL = packageURL ?? originalURL else {
                swiftTool.diagnostics.emit(.missingRequiredArg("--original-url"))
                throw ExitCode.failure
            }

            if let mirror = config.mirrors.mirrorURL(for: originalURL) {
                print(mirror)
            } else {
                stderrStream <<< "not found\n"
                stderrStream.flush()
                throw ExitCode.failure
            }
        }
    }
}

extension SwiftPackageTool {
    struct ResolveOptions: ParsableArguments {
        @Option(help: "The version to resolve at", transform: { Version(string: $0) })
        var version: Version?
        
        @Option(help: "The branch to resolve at")
        var branch: String?
        
        @Option(help: "The revision to resolve at")
        var revision: String?

        @Argument(help: "The name of the package to resolve")
        var packageName: String?
    }
    
    struct Resolve: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resolve package dependencies")
        
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @OptionGroup()
        var resolveOptions: ResolveOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            // If a package is provided, use that to resolve the dependencies.
            if let packageName = resolveOptions.packageName {
                let workspace = try swiftTool.getActiveWorkspace()
                try workspace.resolve(
                    packageName: packageName,
                    root: swiftTool.getWorkspaceRoot(),
                    version: resolveOptions.version,
                    branch: resolveOptions.branch,
                    revision: resolveOptions.revision,
                    diagnostics: swiftTool.diagnostics)
                if swiftTool.diagnostics.hasErrors {
                    throw ExitCode.failure
                }
            } else {
                // Otherwise, run a normal resolve.
                try swiftTool.resolve()
            }
        }
    }
    
    struct Fetch: SwiftCommand {
        static let configuration = CommandConfiguration(shouldDisplay: false)
        
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @OptionGroup()
        var resolveOptions: ResolveOptions
        
        func run(_ swiftTool: SwiftTool) throws {
            swiftTool.diagnostics.emit(warning: "'fetch' command is deprecated; use 'resolve' instead")
            
            let resolveCommand = Resolve(swiftOptions: _swiftOptions, resolveOptions: _resolveOptions)
            try resolveCommand.run(swiftTool)
        }
    }
}

extension SwiftPackageTool {
    struct CompletionTool: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Completion tool (for shell completions)"
        )

        enum Mode: String, CaseIterable, ExpressibleByArgument {
            case generateBashScript = "generate-bash-script"
            case generateZshScript = "generate-zsh-script"
            case generateFishScript = "generate-fish-script"
            case listDependencies = "list-dependencies"
            case listExecutables = "list-executables"
        }

        /// A dummy version of the root `swift` command, to act as a parent
        /// for all the subcommands.
        fileprivate struct SwiftCommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "swift",
                abstract: "The Swift compiler",
                subcommands: [
                    SwiftRunTool.self,
                    SwiftBuildTool.self,
                    SwiftTestTool.self,
                    SwiftPackageTool.self,
                ]
            )
        }
      
        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        @Argument(help: "generate-bash-script | generate-zsh-script |\ngenerate-fish-script | list-dependencies | list-executables")
        var mode: Mode

        func run(_ swiftTool: SwiftTool) throws {
            switch mode {
            case .generateBashScript:
                let script = SwiftCommand.completionScript(for: .bash)
                print(script)
            case .generateZshScript:
                let script = SwiftCommand.completionScript(for: .zsh)
                print(script)
            case .generateFishScript:
                let script = SwiftCommand.completionScript(for: .fish)
                print(script)
            case .listDependencies:
                let graph = try swiftTool.loadPackageGraph()
                dumpDependenciesOf(rootPackage: graph.rootPackages[0], mode: .flatlist)
            case .listExecutables:
                let graph = try swiftTool.loadPackageGraph()
                let package = graph.rootPackages[0].underlyingPackage
                let executables = package.targets.filter { $0.type == .executable }
                for executable in executables {
                    stdoutStream <<< "\(executable.name)\n"
                }
                stdoutStream.flush()
            }
        }
    }
}

private extension Diagnostic.Message {
    static var missingRequiredSubcommand: Diagnostic.Message {
        .error("missing required subcommand; use --help to list available subcommands")
    }

    static func missingRequiredArg(_ argument: String) -> Diagnostic.Message {
        .error("missing required argument \(argument)")
    }
}

/// Logs all changed dependencies to a stream
/// - Parameter changes: Changes to log
/// - Parameter pins: PinsStore with currently pinned packages to compare changed packages to.
/// - Parameter stream: Stream used for logging
fileprivate func logPackageChanges(changes: [(PackageReference, Workspace.PackageStateChange)], pins: PinsStore, on stream: OutputByteStream = TSCBasic.stdoutStream) {
    let changes = changes.filter { $0.1 != .unchanged }
    
    stream <<< "\n"
    stream <<< "\(changes.count) dependenc\(changes.count == 1 ? "y has" : "ies have") changed\(changes.count > 0 ? ":" : ".")"
    stream <<< "\n"
    
    for (package, change) in changes {
        let currentVersion = pins.pinsMap[package.identity]?.state.description ?? ""
        switch change {
        case let .added(state):
            stream <<< "+ \(package.name) \(state.requirement.prettyPrinted)"
        case let .updated(state):
            stream <<< "~ \(package.name) \(currentVersion) -> \(package.name) \(state.requirement.prettyPrinted)"
        case .removed:
            stream <<< "- \(package.name) \(currentVersion)"
        case .unchanged:
            continue
        }
        stream <<< "\n"
    }
    stream.flush()
}

internal struct PackageTemplate: Codable {
    struct Directories: Codable {
        let sources: RelativePath
        let tests: RelativePath?
        let createSubDirectoryForModule: Bool
    }
    
    enum DependencyType: String, Codable {
        case from
        case range
        case exact
        case branch
        case revision
        case path
    }
    
    struct PackageDependency: Codable {
        let url: String
        let version: String
    }
    
    enum PackageType: String, Codable {
        case executable
        case library
        case systemModule = "system-module"
        case empty
        case manifest
    }
    
    let directories: Directories
    let type: PackageType
    let dependencies: [PackageDependency]
}

extension InitPackage.PackageTemplate {
    internal init(template: PackageTemplate) {

        let packageType: InitPackage.PackageType
        switch template.type {
        case .executable:
            packageType = .executable
        case .library:
            packageType = .library
        case .systemModule:
            packageType = .systemModule
        case .empty:
            packageType = .empty
        case .manifest:
            packageType = .manifest
        }

        self.init(sourcesDirectory: template.directories.sources,
                  testsDirectory: template.directories.tests,
                  createSubDirectoryForModule: template.directories.createSubDirectoryForModule,
                  packageType: packageType)
    }
}

internal func getSwiftPMDefaultTemplate(
    type: InitPackage.PackageType,
    sources: RelativePath = .init("./Sources"),
    tests: RelativePath? = nil,
    createSubDirectoryForModule: Bool = false
) -> PackageTemplate {
    // Even if we are making a "classic" package that doesn't use a template we should till use templates
    // for consistency within the codebase
    let defaultDir = PackageTemplate.Directories(sources: sources, tests: tests, createSubDirectoryForModule: createSubDirectoryForModule)
    let defaultDependencies = [PackageTemplate.PackageDependency]()
    let packageType: PackageTemplate.PackageType

    switch type {
    case .executable:
        packageType = .executable
    case .library:
        packageType = .library
    case .systemModule:
        packageType = .systemModule
    case .empty:
        packageType = .empty
    case .manifest:
        packageType = .manifest
    default:
        packageType = .library
    }
    
    return PackageTemplate(directories: defaultDir, type: packageType, dependencies: defaultDependencies)
}

fileprivate func makePackage(
    filesystem: FileSystem,
    configPath: AbsolutePath,
    packageName: String?,
    mode: MakePackageMode,
    packageType: InitPackage.PackageType,
    packageTemplate: String?
) throws {
    guard let cwd = filesystem.currentWorkingDirectory else {
        throw InternalError("Could not find the current working directroy.")
    }
    
//        guard !(type != nil && packageTemplate != nil) else {
//            throw InternalError("Can't use --type in conjunction with --template.")
//        }
    
    let name: String
    let destinationPath: AbsolutePath
    let templateHomeDirectory = configPath.appending(components: "templates", "new-package")
    
    var foundTemplate = false
    var templateToUse = ""
    
    if let templateName = packageTemplate {
        // All templates need to be stored in:
        // ~/.swiftpm/configuration/templates/new-package/
        guard filesystem.exists(templateHomeDirectory.appending(component: templateName + ".json")) else {
            throw InternalError("Could not find template \(templateName).json in: \(templateHomeDirectory.pathString)/templates/new-package/")
        }
        
        templateToUse = templateName
        foundTemplate = true
    } else {
        // Checking if a default template is present
        if filesystem.exists(templateHomeDirectory.appending(component: "default.json")) {
            templateToUse = "default.json"
            foundTemplate = true
        }
    }
    
    let packageTemplate: InitPackage.PackageTemplate
    if foundTemplate {
        let url = URL(fileURLWithPath: templateHomeDirectory.appending(component: templateToUse + ".json").pathString)
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder.makeWithDefaults()
        let templateFromJSON = try decoder.decode(PackageTemplate.self, from: data)
        packageTemplate = InitPackage.PackageTemplate(template: templateFromJSON)
    } else {
        packageTemplate = InitPackage.PackageTemplate(template: getSwiftPMDefaultTemplate(type: packageType))
    }

    switch mode {
    case .initialize:
        name = packageName ?? cwd.basename
        destinationPath = cwd
    case .create:
        // It's okay to force unwrap here because create has an @Argument for a name
        // ensuring that it will always have a non-nil value
        name = packageName!
        try filesystem.createDirectory(cwd.appending(component: name))
        destinationPath = cwd.appending(component: name)
    }

    let initPackage = try InitPackage(name: name, destinationPath: destinationPath, packageTemplate: packageTemplate)
    initPackage.progressReporter = { message in
        print(message)
    }
    try initPackage.writePackageStructure()
}

fileprivate enum MakePackageMode {
    case `initialize`
    case create
}
