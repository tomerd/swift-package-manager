/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import PackageModel

public struct MockPackage {
    public let name: String
    public let path: String?
    public let platforms: [PlatformDescription]
    public let targets: [MockTarget]
    public let products: [MockProduct]
    public let dependencies: [MockDependency]
    public let versions: [String?]
    // FIXME: This should be per-version.
    public let toolsVersion: ToolsVersion?

    public init(
        name: String,
        path: String? = nil,
        platforms: [PlatformDescription] = [],
        targets: [MockTarget],
        products: [MockProduct],
        dependencies: [MockDependency] = [],
        versions: [String?] = [],
        toolsVersion: ToolsVersion? = nil
    ) {
        self.name = name
        self.path = path
        self.platforms = platforms
        self.targets = targets
        self.products = products
        self.dependencies = dependencies
        self.versions = versions
        self.toolsVersion = toolsVersion
    }

    public static func genericPackage1(named name: String) -> MockPackage {
        return MockPackage(
            name: name,
            targets: [
                MockTarget(name: name),
            ],
            products: [
                MockProduct(name: name, targets: [name]),
            ],
            versions: ["1.0.0"]
        )
    }
}
