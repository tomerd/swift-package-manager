/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Dispatch
import TSCBasic

extension OSLog {
    /// Log for SwiftPM.
    public static let swiftpm = OSLog(subsystem: "org.swift.swiftpm", category: "default")
}

public struct Timer {
    #if DEBUG
    let label: StaticString
    let logMessage: String?

    var startTime: DispatchTime?
    #endif

    public init(label: @autoclosure () -> StaticString, logMessage: @autoclosure () -> String?) {
        #if DEBUG
        self.label = label()
        self.logMessage = logMessage()
        #endif
    }

    public mutating func start() {
        #if DEBUG
        self.startTime = .now()
        os_signpost(.begin, log: .swiftpm, name: self.label)
        #endif
    }

    public func end() {
        #if DEBUG
        os_signpost(.end, log: .swiftpm, name: self.label)
        if let message = self.logMessage, #available(OSX 10.15, *), let duration = self.startTime?.distance(to: .now()).milliseconds() {
           print("  \(message): \(duration) ms")
        }
        #endif
    }

    @inlinable
    @discardableResult
    public static func measure<T>(_ label: @autoclosure () -> StaticString, logMessage: @autoclosure () -> String?, body: () throws -> T) rethrows -> T {
        #if DEBUG
        var timer = Timer(label: label(), logMessage: logMessage())
        timer.start()
        defer { timer.end() }
        #endif
        return try body()
    }
}
