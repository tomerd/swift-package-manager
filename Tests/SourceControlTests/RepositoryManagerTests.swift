/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
@testable import SourceControl

import SPMTestSupport

extension RepositoryManager {
    fileprivate func lookupSync(repository: RepositorySpecifier, skipUpdate: Bool = false) throws -> RepositoryHandle {
        return try tsc_await { self.lookup(repository: repository, skipUpdate: skipUpdate, callbackQueue: .global(), completion: $0) }
    }
}

private enum DummyError: Swift.Error {
    case invalidRepository
}

private class DummyRepository: Repository {
    var tags: [String] = ["1.0.0"]
    unowned let provider: DummyRepositoryProvider

    init(provider: DummyRepositoryProvider) {
        self.provider = provider
    }

    func resolveRevision(tag: String) throws -> Revision {
        fatalError("unexpected API call")
    }

    func resolveRevision(identifier: String) throws -> Revision {
        fatalError("unexpected API call")
    }

    func exists(revision: Revision) -> Bool {
        fatalError("unexpected API call")
    }

    func fetch() throws {
        provider.numFetches += 1
    }

    func openFileView(revision: Revision) throws -> FileSystem {
        fatalError("unexpected API call")
    }
}

private class DummyRepositoryProvider: RepositoryProvider {
    var numClones = 0
    var numFetches: Int {
        get {
            return fetchesLock.withLock {
                return _numFetches
            }
        }
        set {
            fetchesLock.withLock {
                _numFetches = newValue
            }
        }
    }
    private var fetchesLock = Lock()
    var _numFetches = 0
    
    func fetch(repository: RepositorySpecifier, to path: AbsolutePath) throws {
        assert(!localFileSystem.exists(path))
        try localFileSystem.createDirectory(path.parentDirectory, recursive: true)
        try localFileSystem.writeFileContents(path, bytes: ByteString(encodingAsUTF8: repository.url))

        numClones += 1
        
        // We only support one dummy URL.
        let basename = repository.url.components(separatedBy: "/").last!
        if basename != "dummy" {
            throw DummyError.invalidRepository
        }
    }

    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        try localFileSystem.copy(from: sourcePath, to: destinationPath)

        numClones += 1

        // We only support one dummy URL.
        let basename = sourcePath.basename
        if basename != "dummy" {
            throw DummyError.invalidRepository
        }
    }

    func open(repository: RepositorySpecifier, at path: AbsolutePath) -> Repository {
        return DummyRepository(provider: self)
    }

    func cloneCheckout(repository: RepositorySpecifier, at sourcePath: AbsolutePath, to destinationPath: AbsolutePath, editable: Bool) throws {
        try localFileSystem.createDirectory(destinationPath)
        try localFileSystem.writeFileContents(destinationPath.appending(component: "README.txt"), bytes: "Hi")
    }

    func checkoutExists(at path: AbsolutePath) throws -> Bool {
        return false
    }

    func openCheckout(at path: AbsolutePath) throws -> WorkingCheckout {
        fatalError("unsupported")
    }
}

private class DummyRepositoryManagerDelegate: RepositoryManagerDelegate {
    private var _willFetch = [(repository: RepositorySpecifier, fetchDetails: RepositoryManager.FetchDetails?)]()
    private var _didFetch = [(repository: RepositorySpecifier, fetchDetails: RepositoryManager.FetchDetails?)]()

    private var _willUpdate = [RepositorySpecifier]()
    private var _didUpdate = [RepositorySpecifier]()

    private var fetchedLock = Lock() 

    var willFetch: [(repository: RepositorySpecifier, fetchDetails: RepositoryManager.FetchDetails?)] {
        return fetchedLock.withLock({ _willFetch })
    }

    var didFetch: [(repository: RepositorySpecifier, fetchDetails: RepositoryManager.FetchDetails?)] {
        return fetchedLock.withLock({ _didFetch })
    }

    var willUpdate: [RepositorySpecifier] {
        return fetchedLock.withLock({ _willUpdate })
    }

    var didUpdate: [RepositorySpecifier] {
        return fetchedLock.withLock({ _didUpdate })
    }

    func fetchingWillBegin(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?) {
        fetchedLock.withLock {
            _willFetch += [(repository: handle.repository, fetchDetails: fetchDetails)]
        }
    }

    func fetchingDidFinish(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?, error: Swift.Error?) {
        fetchedLock.withLock {
            _didFetch += [(repository: handle.repository, fetchDetails: fetchDetails)]
        }
    }

    func handleWillUpdate(handle: RepositoryManager.RepositoryHandle) {
        fetchedLock.withLock {
            _willUpdate += [handle.repository]
        }
    }

    func handleDidUpdate(handle: RepositoryManager.RepositoryHandle) {
        fetchedLock.withLock {
            _didUpdate += [handle.repository]
        }
    }
}

class RepositoryManagerTests: XCTestCase {
    func testBasics() throws {
        try testWithTemporaryDirectory { path in
            let provider = DummyRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()
            let manager = RepositoryManager(path: path, provider: provider, delegate: delegate)

            // Check that we can "fetch" a repository.
            let dummyRepo = RepositorySpecifier(url: "dummy")

            var prevHandle: RepositoryManager.RepositoryHandle?
            let handle = try manager.lookupSync(repository: dummyRepo)
            

            prevHandle = handle
            XCTAssertEqual(provider.numFetches, 0)
        
            // Open the repository.
            let repository = try! handle.open()
            XCTAssertEqual(repository.tags, ["1.0.0"])

            // Create a checkout of the repository.
            let checkoutPath = path.appending(component: "checkout")
            try! handle.cloneCheckout(to: checkoutPath, editable: false)
        
            XCTAssert(localFileSystem.exists(checkoutPath.appending(component: "README.txt")))
            XCTAssert(localFileSystem.exists(checkoutPath))

            // Get a bad repository.
            let badDummyRepo = RepositorySpecifier(url: "badDummy")
            XCTAssertThrowsError(try manager.lookupSync(repository: badDummyRepo), "expected error") { error in
                XCTAssertEqual(error as? DummyError, DummyError.invalidRepository)
            }

            // We shouldn't have made any update call yet.
            XCTAssert(delegate.willUpdate.isEmpty)
            XCTAssert(delegate.didUpdate.isEmpty)

            // We should always get back the same handle once fetched.
            XCTNonNil(prevHandle) {
                try XCTAssert($0 === manager.lookupSync(repository: dummyRepo))
            }
            // Since we looked up this repo again, we should have made a fetch call.
            XCTAssertEqual(provider.numFetches, 1)
            XCTAssertEqual(delegate.willUpdate, [dummyRepo])
            XCTAssertEqual(delegate.didUpdate, [dummyRepo])

            // Remove the repo.
            try manager.remove(repository: dummyRepo)

            // Check removing the repo updates the persistent file.
            do {
                let checkoutsStateFile = path.appending(component: "checkouts-state.json")
                let jsonData = try JSON(bytes: localFileSystem.readFileContents(checkoutsStateFile))
                XCTAssertEqual(jsonData.dictionary?["object"]?.dictionary?["repositories"]?.dictionary?[dummyRepo.url], nil)
            }

            // We should get a new handle now because we deleted the exisiting repository.
            XCTNonNil(prevHandle) {
                try XCTAssert($0 !== manager.lookupSync(repository: dummyRepo))
            }
            
            // We should have tried fetching these two.
            XCTAssertEqual(Set(delegate.willFetch.map { $0.repository }), [dummyRepo, badDummyRepo])
            XCTAssertEqual(Set(delegate.didFetch .map { $0.repository }), [dummyRepo, badDummyRepo])
        }
    }

    func testCache() throws {
        fixture(name: "DependencyResolution/External/Simple") { prefix in
            let cachePath = prefix.appending(component: "cache")
            let repositoriesPath = prefix.appending(component: "repositories")
            let repo = RepositorySpecifier(url: prefix.appending(component: "Foo").pathString)

            let provider = GitRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()

            let manager = RepositoryManager(path: repositoriesPath, provider: provider, delegate: delegate, cachePath: cachePath)
            manager.cacheLocalPackages = true

            // fetch packages and populate cache
            _ = try manager.lookupSync(repository: repo)
            XCTAssertDirectoryExists(cachePath.appending(component: repo.fileSystemIdentifier))
            XCTAssertDirectoryExists(repositoriesPath.appending(component: repo.fileSystemIdentifier))
            XCTAssertEqual(delegate.willFetch[0].fetchDetails,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: false))
            XCTAssertEqual(delegate.didFetch[0].fetchDetails,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: true))

            try localFileSystem.removeFileTree(repositoriesPath)

            // fetch packages from the cache
            _ = try manager.lookupSync(repository: repo)
            XCTAssertDirectoryExists(repositoriesPath.appending(component: repo.fileSystemIdentifier))
            XCTAssertEqual(delegate.willFetch[1].fetchDetails,
                           RepositoryManager.FetchDetails(fromCache: true, updatedCache: false))
            XCTAssertEqual(delegate.didFetch[1].fetchDetails,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: true))

            try localFileSystem.removeFileTree(repositoriesPath)
            try localFileSystem.removeFileTree(cachePath)

            // fetch packages and populate cache
            _ = try manager.lookupSync(repository: repo)
            XCTAssertDirectoryExists(cachePath.appending(component: repo.fileSystemIdentifier))
            XCTAssertDirectoryExists(repositoriesPath.appending(component: repo.fileSystemIdentifier))
            XCTAssertEqual(delegate.willFetch[2].fetchDetails,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: false))
            XCTAssertEqual(delegate.didFetch[2].fetchDetails,
                           RepositoryManager.FetchDetails(fromCache: false, updatedCache: true))
        }
    }

    func testReset() throws {
        try testWithTemporaryDirectory { path in
            let repos = path.appending(component: "repo")
            let provider = DummyRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()
            try localFileSystem.createDirectory(repos, recursive: true)
            let manager = RepositoryManager(path: repos, provider: provider, delegate: delegate)
            let dummyRepo = RepositorySpecifier(url: "dummy")
            _ = try manager.lookupSync(repository: dummyRepo)
            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            manager.reset()
            XCTAssertTrue(!localFileSystem.isDirectory(repos))
            try localFileSystem.createDirectory(repos, recursive: true)
            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.willFetch.count, 2)
            XCTAssertEqual(delegate.didFetch.count, 2)
        }
    }

    /// Check that the manager is persistent.
    func testPersistence() throws {
        try testWithTemporaryDirectory { path in
            let provider = DummyRepositoryProvider()

            // Do the initial fetch.
            do {
                let delegate = DummyRepositoryManagerDelegate()
                let manager = RepositoryManager(path: path, provider: provider, delegate: delegate)
                let dummyRepo = RepositorySpecifier(url: "dummy")

                _ = try manager.lookupSync(repository: dummyRepo)

                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo])
            }
            // We should have performed one fetch.
            XCTAssertEqual(provider.numClones, 1)
            XCTAssertEqual(provider.numFetches, 0)

            // Create a new manager, and fetch.
            do {
                let delegate = DummyRepositoryManagerDelegate()
                let manager = RepositoryManager(path: path, provider: provider, delegate: delegate)
                let dummyRepo = RepositorySpecifier(url: "dummy")
                _ = try manager.lookupSync(repository: dummyRepo)
                // This time fetch shouldn't be called.
                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [])
            }
            // We shouldn't have done a new fetch.
            XCTAssertEqual(provider.numClones, 1)
            XCTAssertEqual(provider.numFetches, 1)

            // Manually destroy the manager state, and check it still works.
            do {
                let delegate = DummyRepositoryManagerDelegate()
                var manager = RepositoryManager(path: path, provider: provider, delegate: delegate)
                try! localFileSystem.removeFileTree(path.appending(component: "checkouts-state.json"))
                manager = RepositoryManager(path: path, provider: provider, delegate: delegate)
                let dummyRepo = RepositorySpecifier(url: "dummy")

                _ = try manager.lookupSync(repository: dummyRepo)

                XCTAssertEqual(delegate.willFetch.map { $0.repository }, [dummyRepo])
                XCTAssertEqual(delegate.didFetch.map { $0.repository }, [dummyRepo])
            }
            // We should have re-fetched.
            XCTAssertEqual(provider.numClones, 2)
            XCTAssertEqual(provider.numFetches, 1)
        }
    }

    func testParallelLookups() throws {
        try testWithTemporaryDirectory { path in
            let provider = DummyRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()
            let manager = RepositoryManager(path: path, provider: provider, delegate: delegate)
            let dummyRepo = RepositorySpecifier(url: "dummy")
            // Condition to check if we have finished all lookups.
            let doneCondition = Condition()
            var done = false
            var set = Set<Int>()
            let numLookups = 1000

            for i in 0..<numLookups {
                manager.lookup(repository: dummyRepo, callbackQueue: .global()) { _ in
                 doneCondition.whileLocked {
                        set.insert(i)
                        if set.count == numLookups {
                            // If set has all the lookups, we're done.
                            done = true
                            doneCondition.signal()
                        }
                    }
                }
            }
            // Block until all the lookups are done.
            doneCondition.whileLocked {
                while !done {
                    doneCondition.wait()
                }
            }
        }
    }

    func testSkipUpdate() throws {
        try testWithTemporaryDirectory { path in
            let repos = path.appending(component: "repo")
            let provider = DummyRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()
            try localFileSystem.createDirectory(repos, recursive: true)

            let manager = RepositoryManager(path: repos, provider: provider, delegate: delegate)
            let dummyRepo = RepositorySpecifier(url: "dummy")

            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, 0)
            XCTAssertEqual(delegate.didUpdate.count, 0)

            _ = try manager.lookupSync(repository: dummyRepo)
            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, 2)
            XCTAssertEqual(delegate.didUpdate.count, 2)

            _ = try manager.lookupSync(repository: dummyRepo, skipUpdate: true)
            XCTAssertEqual(delegate.willFetch.count, 1)
            XCTAssertEqual(delegate.didFetch.count, 1)
            XCTAssertEqual(delegate.willUpdate.count, 2)
            XCTAssertEqual(delegate.didUpdate.count, 2)
        }
    }

    func testStateFileResilience() throws {
        try testWithTemporaryDirectory { path in
            // Setup a dummy repository.
            let repos = path.appending(component: "repo")
            let provider = DummyRepositoryProvider()
            let delegate = DummyRepositoryManagerDelegate()
            try localFileSystem.createDirectory(repos, recursive: true)
            let manager = RepositoryManager(path: repos, provider: provider, delegate: delegate)
            let dummyRepo = RepositorySpecifier(url: "dummy")

            // Perform a lookup.
            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.didFetch.count, 1)

            // Delete the checkout state file.
            let stateFile = repos.appending(component: "checkouts-state.json")
            try localFileSystem.removeFileTree(stateFile)

            // We should refetch the repository since we lost the state file.
            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.didFetch.count, 2)

            // This time remove the entire repository directory and expect that
            // to work as well.
            try localFileSystem.removeFileTree(repos)
            _ = try manager.lookupSync(repository: dummyRepo)
            XCTAssertEqual(delegate.didFetch.count, 3)
        }
    }
}
