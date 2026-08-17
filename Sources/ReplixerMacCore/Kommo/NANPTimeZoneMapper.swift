import Foundation

/// Phase 10.1c (revision) — Swift port of Google libphonenumber's
/// `PhoneNumberToTimeZonesMapper` geocoder, scoped to NANP (country calling
/// code "1": US, Canada, and Caribbean territories) — the only calling code
/// `KommoService.resolveTimeZone(fromPhone:)` ever consults this table for
/// (see its "US" region gate, unchanged by this revision). Windows reaches
/// the real thing directly via the `libphonenumber-csharp` NuGet package;
/// there's no equivalent Swift package, so rather than hand-maintaining a
/// per-area-code table (the retired `USAreaCodeTimeZones`, which only
/// matched at 3-digit area-code granularity and got known-split codes like
/// ID 208 / KS 620 / NE 308 wrong), this ports libphonenumber's own
/// published geocoder data file — same data Windows' dependency is built
/// from, so this now resolves those split codes correctly too.
///
/// Data source: `resources/timezones/map_data.txt` from
/// https://github.com/google/libphonenumber (Apache License 2.0, "Generated
/// from: Internal statistics data (2018-06-12)"), filtered down to only the
/// lines whose prefix starts with calling code "1". The filtered subset is
/// bundled at `Kommo/Resources/nanp_timezones.txt` (license header preserved
/// there) via `Package.swift`'s `resources: [.copy(...)]` entry on this
/// target, loaded here through the auto-generated `Bundle.module`. Format
/// per line: `prefix|zone1&zone2&...&zoneN`, where `prefix` is a numeric
/// string beginning with the country calling code, at varying granularity
/// (1, 4, 5, 6, or 7 digits, for this NANP subset).
enum NANPTimeZoneMapper {
    /// Longest-prefix match against the bundled NANP table, mirroring
    /// libphonenumber's own `PrefixTimeZonesMap` lookup: try progressively
    /// shorter prefixes of `digits` (from the dataset's max observed length
    /// down to the 1-digit country-only fallback), returning on the first
    /// match. When a matched entry lists multiple zones — either a number
    /// range that genuinely spans zones, or the single 1-digit
    /// country-level fallback entry with ~40 zones — take the *first* zone
    /// in list order, matching Windows'
    /// `GetTimeZonesForNumber(...).FirstOrDefault()`.
    ///
    /// - Parameter digits: the *full* digit string, country calling code
    ///   included (e.g. "12125551234" for +1 212 555 1234) — NOT just the
    ///   10-digit national number.
    static func timeZone(forDigits digits: String) -> String? {
        var length = min(digits.count, Self.maxPrefixLength)
        while length >= 1 {
            let prefix = String(digits.prefix(length))
            if let zones = table[prefix], let first = zones.split(separator: "&").first {
                return String(first)
            }
            length -= 1
        }
        return nil
    }

    // Longest prefix key actually present in nanp_timezones.txt (verified
    // against the source data at the time it was filtered from
    // libphonenumber's map_data.txt) — starting the scan any higher would
    // just be wasted lookups against keys that can never exist.
    private static let maxPrefixLength = 7

    private static let table: [String: String] = {
        guard let url = Bundle.module.url(forResource: "nanp_timezones", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("NANPTimeZoneMapper: nanp_timezones.txt resource missing from bundle")
            return [:]
        }

        var t: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            // Skip blank lines and the Apache-2.0 attribution header —
            // every non-data line in the bundled file starts with "#".
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let pipeIndex = line.firstIndex(of: "|")
            else { continue }
            let prefix = String(line[line.startIndex..<pipeIndex])
            let zones = String(line[line.index(after: pipeIndex)...])
            t[prefix] = zones
        }
        return t
    }()
}
