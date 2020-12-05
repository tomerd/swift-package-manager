/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import SourceControl
import TSCUtility

import SPMTestSupport

class InMemoryGitRepositoryTests: XCTestCase {
    func testBasics() throws {
        let fs = InMemoryFileSystem()
        let repo = InMemoryGitRepository(path: .root, fs: fs)

        try repo.createDirectory(AbsolutePath("/new-dir/subdir"), recursive: true)
        XCTAssertFalse(try repo.hasUncommittedChanges())
        let filePath = AbsolutePath("/new-dir/subdir").appending(component: "new-file.txt")

        try repo.writeFileContents(filePath, bytes: "one")
        XCTAssertEqual(try repo.readFileContents(filePath), "one")
        XCTAssertTrue(try repo.hasUncommittedChanges())

        let firstCommit = repo.commit()
        XCTAssertFalse(try repo.hasUncommittedChanges())

        XCTAssertEqual(try repo.readFileContents(filePath), "one")
        XCTAssertEqual(try fs.readFileContents(filePath), "one")

        try repo.writeFileContents(filePath, bytes: "two")
        XCTAssertEqual(try repo.readFileContents(filePath), "two")
        XCTAssertTrue(try repo.hasUncommittedChanges())

        let secondCommit = repo.commit()
        XCTAssertFalse(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "two")

        try repo.writeFileContents(filePath, bytes: "three")
        XCTAssertTrue(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "three")

        try repo.checkout(revision: firstCommit)
        XCTAssertFalse(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "one")
        XCTAssertEqual(try fs.readFileContents(filePath), "one")

        try repo.checkout(revision: secondCommit)
        XCTAssertFalse(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "two")

        XCTAssert(try repo.tags().isEmpty)
        try repo.tag(name: "2.0.0")
        XCTAssertEqual(try repo.tags(), ["2.0.0"])
        XCTAssertFalse(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "two")
        XCTAssertEqual(try fs.readFileContents(filePath), "two")

        try repo.checkout(revision: firstCommit)
        XCTAssertFalse(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "one")

        try repo.checkout(tag: "2.0.0")
        XCTAssertFalse(try repo.hasUncommittedChanges())
        XCTAssertEqual(try repo.readFileContents(filePath), "two")
    }

    func testProvider() throws {
        let v1 = "1.0.0"
        let v2 = "2.0.0"
        let repo = InMemoryGitRepository(path: .root, fs: InMemoryFileSystem())

        let specifier = RepositorySpecifier(url: "/foo")
        try repo.createDirectory(AbsolutePath("/new-dir/subdir"), recursive: true)
        let filePath = AbsolutePath("/new-dir/subdir").appending(component: "new-file.txt")
        try repo.writeFileContents(filePath, bytes: "one")
        repo.commit()
        try repo.tag(name: v1)
        try repo.writeFileContents(filePath, bytes: "two")
        repo.commit()
        try repo.tag(name: v2)

        let provider = InMemoryGitRepositoryProvider()
        provider.add(specifier: specifier, repository: repo)

        let fooRepoPath = AbsolutePath("/fooRepo")
        try provider.fetch(repository: specifier, to: fooRepoPath)
        let fooRepo = try provider.open(repository: specifier, at: fooRepoPath)

        // Adding a new tag in original repo shouldn't show up in fetched repo.
        try repo.tag(name: "random")
        XCTAssertEqual(try fooRepo.tags().sorted(), [v1, v2])
        XCTAssert(try fooRepo.exists(revision: try fooRepo.resolveRevision(tag: v1)))

        let fooCheckoutPath = AbsolutePath("/fooCheckout")
        XCTAssertFalse(try provider.checkoutExists(at: fooCheckoutPath))
        try provider.cloneCheckout(repository: specifier, at: fooRepoPath, to: fooCheckoutPath, editable: false)
        XCTAssertTrue(try provider.checkoutExists(at: fooCheckoutPath))
        let fooCheckout = try provider.openCheckout(at: fooCheckoutPath)

        XCTAssertEqual(try fooCheckout.tags2().sorted(), [v1, v2])
        XCTAssert(try fooCheckout.exists2(revision: try fooCheckout.getCurrentRevision()))
        let checkoutRepo = provider.openRepo(at: fooCheckoutPath)

        try fooCheckout.checkout(tag: v1)
        XCTAssertEqual(try checkoutRepo.readFileContents(filePath), "one")

        try fooCheckout.checkout(tag: v2)
        XCTAssertEqual(try checkoutRepo.readFileContents(filePath), "two")
    }
}
