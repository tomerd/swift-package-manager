//
//  File.swift
//  
//
//  Created by Tom Doron on 12/26/20.
//

extension Array {
    // TODO: keypath version would be nice
    public func reduce<Key>(_ extractor: (Element) throws -> Key) rethrows -> [Key: Element] {
        try Dictionary(self.map{ ( try extractor($0), $0) }, uniquingKeysWith: { $1 })
    }

    public func uniqueKeysWithValues<Key, Value>() -> [Key: Value] where Element == (Key, Value) {
        Dictionary(uniqueKeysWithValues: self)
    }
}
