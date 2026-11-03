import Foundation

struct PublishedReference: Encodable, Sendable {
    let kind: PublicationKind
    let venue: String
    let year: Int?

    private static let session = URLSession(configuration: .ephemeral)

    static func lookup(_ doi: String?) async -> Self? {
        guard let doi = doi?.trimmingCharacters(in: .whitespacesAndNewlines),
              doi.range(of: #"\A10\.\d{4,9}/\S+\z"#, options: .regularExpression) != nil,
              !doi.lowercased().hasPrefix("10.48550/") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.crossref.org"
        components.path = "/works/\(doi)"
        guard let url = components.url else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> Self? {
        guard let work = try? JSONDecoder().decode(CrossrefResponse.self, from: data).message else { return nil }
        let kind: PublicationKind
        let dates: [DateParts?]
        let title = work.containerTitle?.first(where: { !$0.isEmpty })
        let name: String?
        switch work.type {
        case "journal-article":
            kind = .journal
            dates = [work.print, work.published, work.online, work.issued]
            name = title
        case "proceedings-article":
            kind = .conference
            dates = [work.event?.start, work.published, work.print, work.online, work.issued]
            name = work.event?.name ?? title
        default:
            return nil
        }
        guard let venue = name?.trimmingCharacters(in: .whitespacesAndNewlines), !venue.isEmpty else { return nil }
        let year = dates.compactMap { $0?.dateParts?.first?.first }.first(where: PaperClassification.isValidPublicationYear)
        return Self(kind: kind, venue: venue, year: year)
    }

    private struct DateParts: Decodable {
        let dateParts: [[Int]]?
        enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
    }

    private struct CrossrefResponse: Decodable {
        struct Work: Decodable {
            struct Event: Decodable {
                let name: String?
                let start: DateParts?
            }

            let type: String
            let containerTitle: [String]?
            let print: DateParts?
            let published: DateParts?
            let online: DateParts?
            let issued: DateParts?
            let event: Event?

            enum CodingKeys: String, CodingKey {
                case type, published, issued, event
                case containerTitle = "container-title"
                case print = "published-print"
                case online = "published-online"
            }
        }

        let message: Work
    }
}
