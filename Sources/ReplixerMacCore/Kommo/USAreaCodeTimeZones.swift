import Foundation

/// Phase 10.1c — a hand-maintained NANP area-code → IANA-timezone table for
/// `KommoService.resolveTimeZone(fromPhone:)`'s "робочий час" leg. Windows'
/// equivalent (`PhoneNumberToTimeZonesMapper.GetTimeZonesForGeographicalNumber`,
/// from Google's `libphonenumber-csharp` "geocoder" data) resolves timezone
/// from a phone number at *prefix* granularity (sometimes down to the
/// specific exchange) using a proprietary bundled dataset with no Swift
/// equivalent available as a dependency.
///
/// This table is deliberately coarser — one dominant zone per area code —
/// which is exact for the vast majority of codes (historically, NANP area
/// codes were carved out to not cross state/timezone lines) but known to be
/// wrong for a handful of area codes that genuinely straddle two zones (e.g.
/// ID 208, KS 620, NE 308, ND 701, SD 605, OR 541 all have a small
/// Mountain-time sliver inside a mostly-Central/Pacific code — mapped here to
/// whichever zone covers the larger population). Given the actual use case
/// (a rough "is this client likely awake/at work" window, not billing-grade
/// precision), that's an accepted tradeoff rather than a gap to revisit.
///
/// Scope note: only covers area codes Windows' own logic would ever actually
/// resolve via this path — `KommoService.resolveTimeZone` only consults this
/// table for numbers whose region is "US" (Windows: `GetRegionCodeForNumber
/// == "US"`); Canada and NANP territories (Puerto Rico, etc.) have their own
/// distinct region codes and fall through to the same "America/New_York"
/// default every non-US/non-Ukrainian number gets, exactly as on Windows.
enum USAreaCodeTimeZones {
    private static let eastern = "America/New_York"
    private static let central = "America/Chicago"
    private static let mountain = "America/Denver"
    private static let mountainNoDST = "America/Phoenix"
    private static let pacific = "America/Los_Angeles"
    private static let alaska = "America/Anchorage"
    private static let hawaii = "Pacific/Honolulu"

    /// Returns the IANA identifier for a 3-digit US NANP area code, or `nil`
    /// if the code isn't in the table (caller falls back to
    /// "America/New_York", same as any non-US number).
    static func timeZone(forAreaCode areaCode: String) -> String? {
        table[areaCode]
    }

    private static let table: [String: String] = {
        var t: [String: String] = [:]
        func add(_ codes: [String], _ zone: String) {
            for code in codes { t[code] = zone }
        }

        // Connecticut, Delaware, DC, Georgia, Indiana, Kentucky (east),
        // Maine, Maryland, Massachusetts, Michigan, New Hampshire, New
        // Jersey, New York, North Carolina, Ohio, Pennsylvania, Rhode
        // Island, South Carolina, Tennessee (east), Vermont, Virginia, West
        // Virginia, Florida (except panhandle).
        add(["203", "475", "860", "959"], eastern) // CT
        add(["302"], eastern) // DE
        add(["202"], eastern) // DC
        add(["239", "305", "321", "352", "386", "407", "561", "727", "754",
             "772", "786", "813", "863", "904", "941", "954"], eastern) // FL
        add(["229", "404", "470", "478", "678", "706", "762", "770", "912", "943"], eastern) // GA
        add(["219", "260", "317", "463", "574", "765", "812", "930"], eastern) // IN
        add(["502", "606", "859"], eastern) // KY (east)
        add(["207"], eastern) // ME
        add(["240", "301", "410", "443", "667"], eastern) // MD
        add(["339", "351", "413", "508", "617", "774", "781", "857", "978"], eastern) // MA
        add(["231", "248", "269", "313", "517", "586", "616", "679", "734",
             "810", "906", "947", "989"], eastern) // MI
        add(["603"], eastern) // NH
        add(["201", "551", "609", "640", "732", "848", "856", "862", "908", "973"], eastern) // NJ
        add(["212", "315", "329", "332", "347", "363", "516", "518", "585",
             "607", "631", "646", "680", "716", "718", "838", "845", "914",
             "917", "929", "934"], eastern) // NY
        add(["252", "336", "704", "743", "828", "910", "919", "980", "984"], eastern) // NC
        add(["216", "220", "234", "283", "330", "380", "419", "440", "513",
             "567", "614", "740", "937"], eastern) // OH
        add(["215", "223", "267", "272", "412", "445", "484", "570", "582",
             "610", "717", "724", "814", "878"], eastern) // PA
        add(["401"], eastern) // RI
        add(["803", "839", "843", "854", "864"], eastern) // SC
        add(["423", "865"], eastern) // TN (east)
        add(["802"], eastern) // VT
        add(["276", "434", "540", "571", "703", "757", "804"], eastern) // VA
        add(["304", "681"], eastern) // WV

        // Central: Alabama, Arkansas, Florida panhandle, Illinois, Iowa,
        // Kansas, Kentucky (west), Louisiana, Minnesota, Mississippi,
        // Missouri, Nebraska, North Dakota, Oklahoma, South Dakota,
        // Tennessee (middle/west), Texas (most), Wisconsin.
        add(["205", "251", "256", "334", "659", "938"], central) // AL
        add(["327", "479", "501", "870"], central) // AR
        add(["850"], central) // FL panhandle
        add(["217", "224", "309", "312", "331", "618", "630", "708", "730",
             "773", "779", "815", "847", "861", "872"], central) // IL
        add(["319", "515", "563", "641", "712"], central) // IA
        add(["316", "620", "785", "913"], central) // KS
        add(["270", "364"], central) // KY (west)
        add(["225", "318", "337", "468", "504", "985"], central) // LA
        add(["218", "320", "507", "612", "651", "763", "952"], central) // MN
        add(["228", "601", "662", "769"], central) // MS
        add(["314", "417", "573", "636", "660", "816", "975"], central) // MO
        add(["308", "402", "531"], central) // NE
        add(["701"], central) // ND
        add(["405", "539", "580", "918"], central) // OK
        add(["605"], central) // SD
        add(["615", "629", "731", "901", "931"], central) // TN (middle/west)
        add(["210", "214", "254", "281", "325", "346", "361", "409", "430",
             "432", "469", "512", "682", "713", "726", "737", "806", "817",
             "830", "832", "903", "936", "940", "945", "956", "972", "979"], central) // TX (most)
        add(["262", "274", "414", "534", "608", "715", "920"], central) // WI

        // Mountain (observes DST): Colorado, Idaho, Montana, New Mexico,
        // Utah, Wyoming, and El Paso TX.
        add(["303", "719", "720", "970", "983"], mountain) // CO
        add(["208", "986"], mountain) // ID
        add(["406"], mountain) // MT
        add(["505", "575"], mountain) // NM
        add(["385", "435", "801"], mountain) // UT
        add(["307"], mountain) // WY
        add(["915"], mountain) // TX (El Paso)

        // Mountain, no DST: Arizona.
        add(["480", "520", "602", "623", "928"], mountainNoDST) // AZ

        // Pacific: California, Nevada, Oregon, Washington.
        add(["209", "213", "279", "310", "323", "341", "408", "415", "424",
             "442", "447", "510", "530", "559", "562", "619", "626", "628",
             "650", "657", "661", "669", "707", "714", "747", "760", "805",
             "818", "820", "831", "840", "858", "909", "916", "925", "949",
             "951"], pacific) // CA
        add(["702", "725", "775"], pacific) // NV
        add(["458", "503", "541", "971"], pacific) // OR
        add(["206", "253", "360", "425", "509", "564"], pacific) // WA

        add(["907"], alaska)
        add(["808"], hawaii)

        return t
    }()
}
