import Foundation

final class PolarAdapter: RevenueProviderAdapter {
    var provider: ProviderKind { .polar }

    private let client: HTTPClient
    private let calendar: Calendar
    private let baseURL = "https://api.polar.sh/v1"
    private let tokenScopedEntityID = "polar-token-scope"
    private let supportedCurrency = "USD"

    init(client: HTTPClient, calendar: Calendar = .current) {
        self.client = client
        self.calendar = calendar
    }

    func validateKey(_ key: String) async throws {
        _ = try await request(path: "/orders/?limit=1", key: key)
    }

    func listSelectableEntities(using key: String) async throws -> [ProviderEntity] {
        do {
            let json = try await request(path: "/organizations/?limit=100", key: key)
            let organizations: [[String: Any]] = parseCollection(json)
            let entities: [ProviderEntity] = organizations.compactMap { (org: [String: Any]) -> ProviderEntity? in
                let id = org.string("id") ?? org.string("uuid") ?? ""
                let name = org.string("name") ?? org.string("slug") ?? "Organization \(id)"
                guard !id.isEmpty else { return nil }
                return ProviderEntity(id: id, name: name)
            }

            if !entities.isEmpty {
                return entities
            }
        } catch {
            // Some production Polar tokens can query orders/subscriptions but not organizations listing.
            // Fallback to a token-scoped single entity so onboarding can continue.
        }

        try await validateKey(key)
        return [ProviderEntity(id: tokenScopedEntityID, name: "Polar (Current Token)")]
    }

    func fetchRevenueSnapshot(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> ProviderRevenueSnapshot {
        try ensureSupportedCurrency(currency)
        let orders = try await fetchPaginatedCollection(
            path: scopedPath(resource: "orders", entityID: entity.id, limit: 100),
            key: key
        )

        var events: [RevenueEvent] = []
        for order in orders {
            guard
                let createdAt = order.date("created_at") ?? order.date("createdAt") ?? order.date("timestamp"),
                let amountMinor = parseAmountMinor(order: order)
            else {
                continue
            }

            let sourceCurrency = order.string("currency")?.uppercased()
                ?? order.string("currency_code")?.uppercased()
                ?? "USD"

            let usdAmount = try usdOnlyAmount(
                minorUnits: amountMinor,
                sourceCurrency: sourceCurrency,
                context: "Polar order"
            )

            events.append(RevenueEvent(timestamp: createdAt, amount: usdAmount))
        }

        return AdapterSupport.grossSnapshot(events: events, currency: currency, now: now, calendar: calendar)
    }

    func fetchMrr(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> MonetaryAmount {
        try ensureSupportedCurrency(currency)
        let subscriptions = try await fetchPaginatedCollection(
            path: scopedPath(resource: "subscriptions", entityID: entity.id, limit: 100),
            key: key
        )

        var total: Int64 = 0

        for item in subscriptions {
            let status = (item.string("status") ?? "").lowercased()
            if !status.isEmpty, status != "active" {
                continue
            }

            guard let amountMinor = parseSubscriptionAmountMinor(subscription: item) else {
                continue
            }

            let sourceCurrency = item.string("currency")?.uppercased()
                ?? item.string("currency_code")?.uppercased()
                ?? "USD"

            let intervalRaw = (item.string("recurring_interval") ?? item.string("interval") ?? item.string("billing_interval") ?? "month").lowercased()
            let interval: BillingInterval
            switch intervalRaw {
            case "day", "daily":
                interval = .day
            case "week", "weekly":
                interval = .week
            case "year", "yearly", "annual":
                interval = .year
            default:
                interval = .month
            }

            let intervalCount = max(1, Int(item.int64("interval_count") ?? item.int64("billing_interval_count") ?? 1))
            let quantity = max(1, Int(item.int64("quantity") ?? 1))

            let usdAmount = try usdOnlyAmount(
                minorUnits: amountMinor,
                sourceCurrency: sourceCurrency,
                context: "Polar subscription"
            )

            total += AdapterSupport.normalizedMonthlyMinorUnits(for: RecurringRevenueItem(
                amount: usdAmount,
                interval: interval,
                intervalCount: intervalCount,
                quantity: quantity
            ))
        }

        return MonetaryAmount(minorUnits: total, currencyCode: currency)
    }

    private func request(path: String, key: String) async throws -> Any {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setBearerToken(key)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            return try await client.sendJSON(request)
        } catch ProviderAdapterError.unauthorized {
            throw ProviderAdapterError.unsupported(
                "Polar token rejected on production API. Ensure it is a production OAT token with organizations:read, orders:read, subscriptions:read."
            )
        }
    }

    private func fetchPaginatedCollection(path: String, key: String) async throws -> [[String: Any]] {
        var allItems: [[String: Any]] = []
        var nextPath: String? = path
        var pages = 0
        let maxPages = 100

        while let currentPath = nextPath, pages < maxPages {
            let json = try await request(path: currentPath, key: key)
            let pageItems = parseCollection(json)
            allItems.append(contentsOf: pageItems)

            nextPath = parseNextPath(json)
            pages += 1

            if pageItems.isEmpty {
                break
            }
        }

        return allItems
    }

    private func parseCollection(_ json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]] {
            return array
        }

        guard let dictionary = json as? [String: Any] else {
            return []
        }

        if let data = dictionary["data"] as? [[String: Any]] {
            return data
        }
        if let items = dictionary["items"] as? [[String: Any]] {
            return items
        }
        if let results = dictionary["results"] as? [[String: Any]] {
            return results
        }

        return []
    }

    private func parseNextPath(_ json: Any) -> String? {
        guard let dictionary = json as? [String: Any] else {
            return nil
        }

        if let next = dictionary.string("next"), let path = urlPath(from: next) {
            return path
        }

        if let pagination = dictionary.dictionary("pagination"),
           let next = pagination.string("next"),
           let path = urlPath(from: next) {
            return path
        }

        if let links = dictionary.dictionary("links"),
           let next = links.string("next"),
           let path = urlPath(from: next) {
            return path
        }

        return nil
    }

    private func urlPath(from rawValue: String) -> String? {
        if rawValue.hasPrefix("/") {
            return rawValue
        }
        if let url = URL(string: rawValue), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            return components.path.replacingOccurrences(of: "/v1", with: "") + query
        }
        return nil
    }

    private func scopedPath(resource: String, entityID: String, limit: Int) -> String {
        if entityID == tokenScopedEntityID {
            return "/\(resource)/?limit=\(limit)"
        }
        return "/\(resource)/?organization_id=\(entityID)&limit=\(limit)"
    }

    private func parseAmountMinor(order: [String: Any]) -> Int64? {
        if let amount = order.int64("amount") {
            return amount
        }
        if let amount = order.int64("total") {
            return amount
        }
        if let amount = order.int64("amount_in_cents") {
            return amount
        }
        if let amountMajor = order.decimal("amount_decimal") {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }
        return nil
    }

    private func parseSubscriptionAmountMinor(subscription: [String: Any]) -> Int64? {
        if let amount = subscription.int64("amount") {
            return amount
        }
        if let amount = subscription.int64("price") {
            return amount
        }
        if let amount = subscription.int64("amount_in_cents") {
            return amount
        }
        if let amountMajor = subscription.decimal("amount_decimal") {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }
        return nil
    }

    private func ensureSupportedCurrency(_ currency: String) throws {
        guard currency.uppercased() == supportedCurrency else {
            throw ProviderAdapterError.unsupported("RevenueBar is configured for USD only.")
        }
    }

    private func usdOnlyAmount(minorUnits: Int64, sourceCurrency: String, context: String) throws -> MonetaryAmount {
        let normalizedCurrency = sourceCurrency.uppercased()
        guard normalizedCurrency == supportedCurrency else {
            throw ProviderAdapterError.unsupported(
                "Encountered \(normalizedCurrency) in \(context). RevenueBar currently supports USD only."
            )
        }
        return MonetaryAmount(minorUnits: minorUnits, currencyCode: supportedCurrency)
    }
}
