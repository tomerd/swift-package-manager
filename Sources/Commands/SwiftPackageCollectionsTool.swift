/*
 This source file is part of the Swift.org open source project

 Copyright 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import ArgumentParser
import Foundation
import PackageCollections
import PackageModel
import TSCBasic
import TSCUtility

private enum CollectionsError: Swift.Error {
    case invalidArgument(String)
    case invalidVersionString(String)
}

extension CollectionsError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidArgument(let argumentName):
            return "invalid argument '\(argumentName)'"
        case .invalidVersionString(let versionString):
            return "invalid version string '\(versionString)'"
        }
    }
}

struct JSONOptions: ParsableArguments {
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
}

public struct SwiftPackageCollectionsTool: ParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "package-collection",
        _superCommandName: "swift",
        abstract: "Interact with package collections",
        discussion: "SEE ALSO: swift build, swift package, swift run, swift test",
        version: Versioning.currentVersion.completeDisplayString,
        subcommands: [
            Add.self,
            Describe.self,
            List.self,
            Refresh.self,
            Remove.self,
            Search.self
        ],
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    public init() {
    }

    // MARK: Collections

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured collections")

        @OptionGroup
        var jsonOptions: JSONOptions

        mutating func run() throws {
            let collections = try with { collections in
                return try tsc_await { collections.listCollections(identifiers: nil, callback: $0) }
            }

            if jsonOptions.json {
                try JSONEncoder.makeWithDefaults().print(collections)
            } else {
                collections.forEach {
                    print("\($0.name) - \($0.source.url)")
                }
            }
        }
    }

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Refresh configured collections")

        mutating func run() throws {
            let collections = try with { collections in
                return try tsc_await { collections.refreshCollections(callback: $0) }
            }
            print("Refreshed \(collections.count) configured package collections.")
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a new collection")

        @Argument(help: "URL of the collection to add")
        var collectionUrl: String

        @Option(name: .long, help: "Sort order for the added collection")
        var order: Int?

        mutating func run() throws {
            guard let collectionUrl = URL(string: collectionUrl) else {
                throw CollectionsError.invalidArgument("collectionUrl")
            }

            let source = PackageCollectionsModel.CollectionSource(type: .json, url: collectionUrl)
            let collection = try with { collections in
                return try tsc_await { collections.addCollection(source, order: order, callback: $0) }
            }

            print("Added \"\(collection.name)\" to your package collections.")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a configured collection")

        @Argument(help: "URL of the collection to remove")
        var collectionUrl: String

        mutating func run() throws {
            guard let collectionUrl = URL(string: collectionUrl) else {
                throw CollectionsError.invalidArgument("collectionUrl")
            }

            let source = PackageCollectionsModel.CollectionSource(type: .json, url: collectionUrl)
            let collection = try with { collections in
                return try tsc_await { collections.getCollection(source, callback: $0) }
            }

            _ = try with { collections in try tsc_await { collections.removeCollection(source, callback: $0) } }
            print("Removed \"\(collection.name)\" from your package collections.")
        }
    }

    // MARK: Search

    enum SearchMethod: String, EnumerableFlag {
        case keywords
        case module
    }

    struct Search: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Search for packages by keywords or module names")

        @OptionGroup
        var jsonOptions: JSONOptions

        @Flag(help: "Pick the method for searching")
        var searchMethod: SearchMethod

        @Argument(help: "Search query")
        var searchQuery: String

        mutating func run() throws {
            switch searchMethod {
            case .keywords:
                let results = try with { collections in
                    return try tsc_await { collections.findPackages(searchQuery, collections: nil, callback: $0) }
                }
                
                if jsonOptions.json {
                    try JSONEncoder.makeWithDefaults().print(results.items)
                } else {
                    results.items.forEach {
                        print("\($0.package.repository.url): \($0.package.summary ?? "")")
                    }
                }

            case .module:
                let results = try with { collections in
                    return try tsc_await { collections.findTargets(searchQuery, searchType: .exactMatch, collections: nil, callback: $0) }
                }

                let packages = Set(results.items.flatMap { $0.packages })
                if jsonOptions.json {
                    try JSONEncoder.makeWithDefaults().print(packages)
                } else {
                    packages.forEach {
                        print("\($0.repository.url): \($0.summary ?? "")")
                    }
                }
            }
        }
    }

    // MARK: Packages

    struct Describe: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Get metadata for a single package or collection")

        @OptionGroup
        var jsonOptions: JSONOptions

        @Argument(help: "URL of the package or collection to get information for")
        var packageUrl: String

        @Option(name: .long, help: "Version of the package to get information for")
        var version: String?

        private func printVersion(_ version: PackageCollectionsModel.Package.Version?) -> String? {
            guard let version = version else {
                return nil
            }

            let modules = version.targets.compactMap { $0.moduleName }.joined(separator: ", ")
            let platforms = optionalRow("Verified Platforms", version.verifiedPlatforms?.map { $0.name }.joined(separator: ", "))
            let swiftVersions = optionalRow("Verified Swift Versions", version.verifiedSwiftVersions?.map { $0.rawValue }.joined(separator: ", "))
            let license = optionalRow("License", version.license?.type.description)

            return """
            \(version.version)
                Package Name: \(version.packageName)
                Modules: \(modules)\(platforms)\(swiftVersions)\(license)
            """
        }

        mutating func run() throws {
            let identity = PackageIdentity(url: packageUrl)
            let reference = PackageReference.remote(identity: identity, url: packageUrl)
            
            do { // assume URL is for a package
                let result = try with { collections in
                    return try tsc_await { collections.getPackageMetadata(reference, callback: $0) }
                }
                
                if let versionString = version {
                    guard let version = TSCUtility.Version(string: versionString), let result = result.package.versions.first(where: { $0.version == version }), let printedResult = printVersion(result) else {
                        throw CollectionsError.invalidVersionString(versionString)
                    }
                    
                    if jsonOptions.json {
                        try JSONEncoder.makeWithDefaults().print(result)
                    } else {
                        print("\(indent())Version: \(printedResult)")
                    }
                } else {
                    let description = optionalRow("Description", result.package.summary)
                    let versions = result.package.versions.map { "\($0.version)" }.joined(separator: ", ")
                    let watchers = optionalRow("Watchers", result.package.watchersCount?.description)
                    let readme = optionalRow("Readme", result.package.readmeURL?.absoluteString)
                    let authors = optionalRow("Authors", result.package.authors?.map { $0.username }.joined(separator: ", "))
                    let latestVersion = optionalRow("\(String(repeating: "-", count: 60))\n\(indent())Latest Version", printVersion(result.package.latestVersion))

                    if jsonOptions.json {
                        try JSONEncoder.makeWithDefaults().print(result.package)
                    } else {
                        print("""
                            \(description)
                            Available Versions: \(versions)\(watchers)\(readme)\(authors)\(latestVersion)
                        """)
                    }
                }
            } catch { // assume URL is for a collection
                // If a version argument was given, we do not perform the fallback.
                if version != nil {
                    throw error
                }
                
                guard let collectionUrl = URL(string: packageUrl) else {
                    throw CollectionsError.invalidArgument("collectionUrl")
                }
                
                let source = PackageCollectionsModel.CollectionSource(type: .json, url: collectionUrl)
                let collection = try with { collections in
                    try tsc_await { collections.getCollection(source, callback: $0) }
                }
                
                let description = optionalRow("Description", collection.overview)
                let keywords = optionalRow("Keywords", collection.keywords?.joined(separator: ", "))
                let createdAt = optionalRow("Created At", DateFormatter().string(from: collection.createdAt))
                let packages = collection.packages.map { "\($0.repository.url)" }.joined(separator: "\n\(indent(levels: 2))")
                
                if jsonOptions.json {
                    try JSONEncoder.makeWithDefaults().print(collection)
                } else {
                    print("""
                                    Name: \(collection.name)
                                    Source: \(collection.source.url)\(description)\(keywords)\(createdAt)
                                    Packages:
                                        \(packages)
                                """)
                }
            }
        }
    }
}

private func indent(levels: Int = 1) -> String {
    return String(repeating: "    ", count: levels)
}

private func optionalRow(_ title: String, _ contents: String?, indentationLevel: Int = 1) -> String {
    if let contents = contents, !contents.isEmpty {
        return "\n\(indent(levels: indentationLevel))\(title): \(contents)"
    } else {
        return ""
    }
}

private extension JSONEncoder {
    func print<T>(_ value: T) throws where T : Encodable {
        let jsonData = try self.encode(value)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        Swift.print(jsonString)
    }
}

private extension ParsableCommand {
    func with<T>(handler: (_ collections: PackageCollectionsProtocol) throws -> T) throws -> T {
        let collections = PackageCollections()
        defer {
            do {
                try collections.shutdown()
            } catch {
                Self.exit(withError: error)
            }
        }
        
        return try handler(collections)
    }
}
