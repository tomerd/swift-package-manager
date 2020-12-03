/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import TSCBasic

extension Dictionary {
    /// Memoize the value returned by the given closure.
    @inlinable
    @discardableResult
    public mutating func memo(key: Key, lock: Lock, _ body: () throws -> Value) rethrows -> Value {
        if let value = (lock.withLock { self[key] }) {
            return value
        }
        let value = try body()
        lock.withLock {
            self[key] = value
        }
        return value
    }
}
