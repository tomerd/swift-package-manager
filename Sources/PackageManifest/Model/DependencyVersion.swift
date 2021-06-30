extension Package.Dependency {
    public struct Version {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }
    }
}

extension Package.Dependency.Version: Comparable {
    public static func < (lhs: Package.Dependency.Version, rhs: Package.Dependency.Version) -> Bool {
        if lhs.major < rhs.major {
            return true
        }
        if lhs.major == rhs.major, lhs.minor < rhs.minor {
            return true
        }
        if lhs.major == rhs.major, lhs.minor == rhs.minor, lhs.patch < rhs.patch  {
            return true
        }
        return false
    }
}

extension Package.Dependency.Version: ExpressibleByStringLiteral {

    /// Initializes a version struct with the provided string literal.
    ///
    /// - Parameters:
    ///     - version: A string literal to use for creating a new version struct.
    public init(stringLiteral value: String) {
        if let version = Self(value) {
            self.init(version)
        } else {
            // If version can't be initialized using the string literal, report
            // the error and initialize with a dummy value. This is done to
            // report error to the invoking tool (like swift build) gracefully
            // rather than just crashing.
            //errors.append("Invalid semantic version string '\(value)'")
            self.init(0, 0, 0)
        }
    }

    /// Initializes a version struct with the provided extended grapheme cluster.
    ///
    /// - Parameters:
    ///     - version: An extended grapheme cluster to use for creating a new version struct.
    public init(extendedGraphemeClusterLiteral value: String) {
        self.init(stringLiteral: value)
    }

    /// Initializes a version struct with the provided Unicode string.
    ///
    /// - Parameters:
    ///     - version: A Unicode string to use for creating a new version struct.
    public init(unicodeScalarLiteral value: String) {
        self.init(stringLiteral: value)
    }
}

extension Package.Dependency.Version {

    /// Initializes a version struct with the provided version.
    ///
    /// - Parameters:
    ///     - version: A version object to use for creating a new version struct.
    public init(_ version: Self) {
        major = version.major
        minor = version.minor
        patch = version.patch
        //prereleaseIdentifiers = version.prereleaseIdentifiers
        //buildMetadataIdentifiers = version.buildMetadataIdentifiers
    }

    /// Initializes a version struct with the provided version string.
    ///
    /// - Parameters:
    ///     - version: A version string to use for creating a new version struct.
    public init?(_ versionString: String) {
        let prereleaseStartIndex = versionString.firstIndex(of: "-")
        let metadataStartIndex = versionString.firstIndex(of: "+")

        let requiredEndIndex = prereleaseStartIndex ?? metadataStartIndex ?? versionString.endIndex
        let requiredCharacters = versionString.prefix(upTo: requiredEndIndex)
        let requiredComponents = requiredCharacters
            .split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
            .compactMap({ Int($0) })
            .filter({ $0 >= 0 })

        guard requiredComponents.count == 3 else { return nil }

        self.major = requiredComponents[0]
        self.minor = requiredComponents[1]
        self.patch = requiredComponents[2]

        func identifiers(start: String.Index?, end: String.Index) -> [String] {
            guard let start = start else { return [] }
            let identifiers = versionString[versionString.index(after: start)..<end]
            return identifiers.split(separator: ".").map(String.init)
        }

        //self.prereleaseIdentifiers = identifiers(
          //  start: prereleaseStartIndex,
            //end: metadataStartIndex ?? versionString.endIndex)
        //self.buildMetadataIdentifiers = identifiers(start: metadataStartIndex, end: versionString.endIndex)
    }
}
