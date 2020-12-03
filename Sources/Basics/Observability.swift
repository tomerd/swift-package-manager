/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import Dispatch

extension OSLog {
    /// Log for SwiftPM.
    public static let swiftpm = OSLog(subsystem: "org.swift.swiftpm", category: "default")
}


public struct Timer {
    let label: StaticString
    let logMessage: StaticString
    let logArgs: [Any]
    
    var startTime: DispatchTime? = nil
    
    public init(label: StaticString, logMessage: StaticString? = nil, logArgs: [Any]? = nil) {
        self.label = label
        self.logMessage = logMessage ?? label
        self.logArgs = logArgs ?? []
    }
    
    mutating public func start() {
        self.startTime = .now()
        os_signpost(.begin, log: .swiftpm, name: self.label, self.logMessage, self.logArgs)
    }
    
    public func end() {
        os_signpost(.end, log: .swiftpm, name: self.label, self.logMessage, self.logArgs)
        if #available(OSX 10.15, *), let duration = self.startTime?.distance(to: .now()).milliseconds() {
            print("  \(self.logMessage) \(logArgs): \(duration) ms")
        }
    }
    
    @discardableResult
    public static func measure<T>(_ label: StaticString, logMessage: StaticString? = nil, logArgs: [Any]? = nil, body: () throws -> T) rethrows -> T {
        var timer = Timer(label: label, logMessage: logMessage, logArgs: logArgs)
        timer.start()
        defer { timer.end() }
        return try body()
    }
}

