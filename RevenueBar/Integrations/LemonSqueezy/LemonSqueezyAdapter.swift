import Foundation

final class LemonSqueezyAdapter: RevenueProviderAdapter {
    var provider: ProviderKind { .lemonSqueezy }

    private let client: HTTPClient
    private let calendar: Calendar
    private let supportedCurrency = "USD"

    init(client: HTTPClient, calendar: Calendar = .current) {
        self.client = client
        self.calendar = calendar
    }

    func validateKey(_ key: String) async throws {
        _ = try await request(path: "/users/me", key: key)
    }

    func listSelectableEntities(using key: String) async throws -> [ProviderEntity] {
        let json = try await request(path: "/stores?page[size]=100", key: key)
        guard let payload = json as? [String: Any], let data = payload.array("data") else {
            throw ProviderAdapterError.invalidResponse
        }

        return data.compactMap { item in
            let id = item.string("id") ?? ""
            let attributes = item.dictionary("attributes")
            let name = attributes?.string("name") ?? attributes?.string("title") ?? "Store \(id)"
            guard !id.isEmpty else { return nil }
            return ProviderEntity(id: id, name: name)
        }
    }

    func fetchRevenueSnapshot(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> ProviderRevenueSnapshot {
        try ensureSupportedCurrency(currency)
        let storeID = entity.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entity.id
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let dayStart = calendar.startOfDay(for: now)

        let ordersThisMonth = try await fetchOrderEvents(
            storeID: storeID,
            key: key,
            stopWhenOlderThan: monthStart
        )
        let invoicesThisMonth = try await fetchSubscriptionInvoiceEvents(
            storeID: storeID,
            key: key,
            stopWhenOlderThan: monthStart
        )

        let monthlyEvents = ordersThisMonth + invoicesThisMonth
        let thisMonthMinorUnits = monthlyEvents.reduce(0) { $0 + $1.amount.minorUnits }
        let todayMinorUnits = monthlyEvents.reduce(0) { partial, event in
            event.timestamp >= dayStart ? partial + event.amount.minorUnits : partial
        }

        if let metrics = try? await fetchStoreMetrics(storeID: entity.id, key: key) {
            return ProviderRevenueSnapshot(
                today: MonetaryAmount(minorUnits: todayMinorUnits, currencyCode: currency),
                thisMonth: MonetaryAmount(minorUnits: thisMonthMinorUnits, currencyCode: currency),
                last30Days: MonetaryAmount(minorUnits: metrics.thirtyDayRevenueMinorUnits, currencyCode: currency),
                allTime: MonetaryAmount(minorUnits: metrics.totalRevenueMinorUnits, currencyCode: currency)
            )
        }

        // Fallback: compute all windows by full scan if store aggregate metrics are unavailable.
        let allOrderEvents = try await fetchOrderEvents(
            storeID: storeID,
            key: key,
            stopWhenOlderThan: nil
        )
        let allInvoiceEvents = try await fetchSubscriptionInvoiceEvents(
            storeID: storeID,
            key: key,
            stopWhenOlderThan: nil
        )
        return AdapterSupport.grossSnapshot(
            events: allOrderEvents + allInvoiceEvents,
            currency: currency,
            now: now,
            calendar: calendar
        )
    }

    func fetchMrr(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> MonetaryAmount {
        try ensureSupportedCurrency(currency)
        let storeID = entity.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entity.id

        if let customerMrr = try? await fetchMrrFromCustomers(
            storeID: storeID,
            key: key,
            currency: currency
        ) {
            return customerMrr
        }

        let subscriptions = try await fetchPaginated(
            path: "/subscriptions?page[size]=100&filter[store_id]=\(storeID)",
            key: key
        )

        var mrrMinorUnits: Int64 = 0
        var priceCache: [String: LemonSqueezyPriceContext] = [:]
        let includedStatuses: Set<String> = ["on_trial", "active", "paused", "past_due", "unpaid", "cancelled"]

        for subscription in subscriptions {
            guard let attributes = subscription.dictionary("attributes") else { continue }
            let status = (attributes.string("status") ?? "").lowercased()
            if !status.isEmpty, !includedStatuses.contains(status) {
                continue
            }
            if status == "cancelled",
               let endsAt = attributes.date("ends_at"),
               endsAt <= now {
                continue
            }

            let firstItem = attributes.dictionary("first_subscription_item")
            let priceID = firstItem?.string("price_id") ?? firstItem?.int64("price_id").map(String.init)
            let quantity = max(
                1,
                Int(firstItem?.int64("quantity") ?? attributes.int64("quantity") ?? 1)
            )

            let priceContext: LemonSqueezyPriceContext?
            if let priceID {
                if let cached = priceCache[priceID] {
                    priceContext = cached
                } else {
                    let fetched = try? await fetchPriceContext(priceID: priceID, key: key)
                    if let fetched {
                        priceCache[priceID] = fetched
                    }
                    priceContext = fetched
                }
            } else {
                priceContext = nil
            }

            guard let baseAmountMinor = priceContext?.amountMinorUnits ?? parseSubscriptionAmountMinor(attributes: attributes) else {
                continue
            }

            let sourceCurrency = priceContext?.currencyCode
                ?? attributes.string("currency")?.uppercased()
                ?? attributes.string("currency_code")?.uppercased()
                ?? "USD"

            let interval = priceContext?.interval ?? parseInterval(attributes: attributes)
            let intervalCount = max(
                1,
                Int(priceContext?.intervalCount ?? attributes.int64("billing_interval_count") ?? 1)
            )

            let usdAmountMinor = try resolveUSDMinorUnits(
                sourceCurrency: sourceCurrency,
                defaultMinorUnits: baseAmountMinor,
                usdFallbackMinorUnits: parseUSDMinor(attributes: attributes),
                context: "Lemon Squeezy subscription"
            )

            let normalized = AdapterSupport.normalizedMonthlyMinorUnits(for: RecurringRevenueItem(
                amount: MonetaryAmount(minorUnits: usdAmountMinor, currencyCode: supportedCurrency),
                interval: interval,
                intervalCount: intervalCount,
                quantity: quantity
            ))
            mrrMinorUnits += normalized
        }

        return MonetaryAmount(minorUnits: mrrMinorUnits, currencyCode: currency)
    }

    private func request(path: String, key: String) async throws -> Any {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setBearerToken(key)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        return try await client.sendJSON(request)
    }

    private func fetchPaginated(path: String, key: String) async throws -> [[String: Any]] {
        var output: [[String: Any]] = []
        var currentPath: String? = path
        var pages = 0
        let maxPages = 100

        while let path = currentPath, pages < maxPages {
            let json = try await request(path: path, key: key)
            guard let dictionary = json as? [String: Any], let data = dictionary.array("data") else {
                throw ProviderAdapterError.invalidResponse
            }

            output.append(contentsOf: data)

            if let links = dictionary.dictionary("links"),
               let next = links.string("next"),
               !next.isEmpty {
                currentPath = nextPagePath(from: next)
            } else {
                currentPath = nil
            }

            pages += 1
        }

        return output
    }

    private func fetchStoreMetrics(storeID: String, key: String) async throws -> LemonSqueezyStoreMetrics {
        let pathStoreID = storeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? storeID
        let json = try await request(path: "/stores/\(pathStoreID)", key: key)
        guard
            let payload = json as? [String: Any],
            let data = payload.dictionary("data"),
            let attributes = data.dictionary("attributes")
        else {
            throw ProviderAdapterError.invalidResponse
        }

        let totalRevenue = attributes.int64("total_revenue")
            ?? attributes.decimal("total_revenue").map { NSDecimalNumber(decimal: $0).int64Value }
            ?? 0
        let thirtyDayRevenue = attributes.int64("thirty_day_revenue")
            ?? attributes.decimal("thirty_day_revenue").map { NSDecimalNumber(decimal: $0).int64Value }
            ?? 0

        return LemonSqueezyStoreMetrics(
            totalRevenueMinorUnits: totalRevenue,
            thirtyDayRevenueMinorUnits: thirtyDayRevenue
        )
    }

    private func fetchOrderEvents(
        storeID: String,
        key: String,
        stopWhenOlderThan cutoffDate: Date?
    ) async throws -> [RevenueEvent] {
        try await fetchRevenueEvents(
            path: "/orders?page[size]=100&filter[store_id]=\(storeID)",
            key: key,
            stopWhenOlderThan: cutoffDate,
            includeEvent: { attributes in
                let sourceCurrency = attributes.string("currency")?.uppercased()
                    ?? attributes.string("currency_code")?.uppercased()
                    ?? "USD"

                guard let amountMinor = parseAmountMinor(attributes: attributes) else { return nil }
                let usdAmountMinor = try resolveUSDMinorUnits(
                    sourceCurrency: sourceCurrency,
                    defaultMinorUnits: amountMinor,
                    usdFallbackMinorUnits: parseUSDMinor(attributes: attributes),
                    context: "Lemon Squeezy order"
                )
                return MonetaryAmount(minorUnits: usdAmountMinor, currencyCode: supportedCurrency)
            }
        )
    }

    private func fetchSubscriptionInvoiceEvents(
        storeID: String,
        key: String,
        stopWhenOlderThan cutoffDate: Date?
    ) async throws -> [RevenueEvent] {
        try await fetchRevenueEvents(
            path: "/subscription-invoices?page[size]=100&filter[store_id]=\(storeID)",
            key: key,
            stopWhenOlderThan: cutoffDate,
            includeEvent: { attributes in
                let billingReason = (attributes.string("billing_reason") ?? "").lowercased()
                if billingReason == "initial" {
                    return nil
                }

                let status = (attributes.string("status") ?? "").lowercased()
                let includedStatuses: Set<String> = ["paid", "refunded", "partial_refund"]
                if !includedStatuses.contains(status) {
                    return nil
                }

                let sourceCurrency = attributes.string("currency")?.uppercased()
                    ?? attributes.string("currency_code")?.uppercased()
                    ?? "USD"

                guard let amountMinor = parseAmountMinor(attributes: attributes) else { return nil }
                let usdAmountMinor = try resolveUSDMinorUnits(
                    sourceCurrency: sourceCurrency,
                    defaultMinorUnits: amountMinor,
                    usdFallbackMinorUnits: parseUSDMinor(attributes: attributes),
                    context: "Lemon Squeezy subscription invoice"
                )

                return MonetaryAmount(minorUnits: usdAmountMinor, currencyCode: supportedCurrency)
            }
        )
    }

    private func fetchRevenueEvents(
        path: String,
        key: String,
        stopWhenOlderThan cutoffDate: Date?,
        includeEvent: ([String: Any]) throws -> MonetaryAmount?
    ) async throws -> [RevenueEvent] {
        var events: [RevenueEvent] = []
        var currentPath: String? = path
        var pages = 0
        let maxPages = 100
        var shouldStop = false

        while let path = currentPath, pages < maxPages, !shouldStop {
            let json = try await request(path: path, key: key)
            guard let dictionary = json as? [String: Any], let data = dictionary.array("data") else {
                throw ProviderAdapterError.invalidResponse
            }

            for row in data {
                guard
                    let attributes = row.dictionary("attributes"),
                    let createdAt = attributes.date("created_at") ?? attributes.date("createdAt")
                else { continue }

                if let cutoffDate, createdAt < cutoffDate {
                    shouldStop = true
                    break
                }

                guard let amount = try includeEvent(attributes) else { continue }
                events.append(RevenueEvent(timestamp: createdAt, amount: amount))
            }

            if shouldStop {
                break
            }

            if let links = dictionary.dictionary("links"),
               let next = links.string("next"),
               !next.isEmpty {
                currentPath = nextPagePath(from: next)
            } else {
                currentPath = nil
            }

            pages += 1
        }

        return events
    }

    private func fetchMrrFromCustomers(
        storeID: String,
        key: String,
        currency: String
    ) async throws -> MonetaryAmount? {
        let customers = try await fetchPaginated(
            path: "/customers?page[size]=100&filter[store_id]=\(storeID)",
            key: key
        )

        var totalMrr: Int64 = 0
        var foundMrrField = false

        for customer in customers {
            guard let attributes = customer.dictionary("attributes") else { continue }
            if let mrr = attributes.int64("mrr") {
                foundMrrField = true
                totalMrr += max(0, mrr)
            }
        }

        guard foundMrrField else {
            return nil
        }

        return MonetaryAmount(minorUnits: totalMrr, currencyCode: currency)
    }

    private func nextPagePath(from rawValue: String) -> String? {
        if rawValue.hasPrefix("/") {
            return rawValue.replacingOccurrences(of: "/v1", with: "")
        }

        guard
            let url = URL(string: rawValue),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let querySuffix = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return components.path.replacingOccurrences(of: "/v1", with: "") + querySuffix
    }

    private func fetchPriceContext(priceID: String, key: String) async throws -> LemonSqueezyPriceContext? {
        let pathPriceID = priceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? priceID
        let json = try await request(path: "/prices/\(pathPriceID)", key: key)
        guard
            let payload = json as? [String: Any],
            let data = payload.dictionary("data"),
            let attributes = data.dictionary("attributes")
        else {
            return nil
        }

        guard let amountMinorUnits = parsePriceAmountMinor(attributes: attributes) else {
            return nil
        }

        let intervalRaw = (
            attributes.string("renewal_interval_unit") ??
            attributes.string("billing_interval") ??
            attributes.string("interval") ??
            "month"
        ).lowercased()

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

        let intervalCount = max(
            1,
            attributes.int64("renewal_interval_quantity")
                ?? attributes.int64("billing_interval_count")
                ?? 1
        )

        let currencyCode = attributes.string("currency")?.uppercased()
            ?? attributes.string("currency_code")?.uppercased()

        return LemonSqueezyPriceContext(
            amountMinorUnits: amountMinorUnits,
            interval: interval,
            intervalCount: intervalCount,
            currencyCode: currencyCode
        )
    }

    private func parseAmountMinor(attributes: [String: Any]) -> Int64? {
        if let amount = attributes.int64("total") {
            return amount
        }
        if let amount = attributes.int64("subtotal") {
            return amount
        }
        if let amount = attributes.int64("total_usd") {
            return amount
        }
        if let amount = attributes.int64("grand_total") {
            return amount
        }
        if let amountMajor = attributes.decimal("total_usd"), amountMajor < 1_000_000 {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }
        if let amountMajor = attributes.decimal("grand_total"), amountMajor < 1_000_000 {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }
        return nil
    }

    private func parsePriceAmountMinor(attributes: [String: Any]) -> Int64? {
        if let amount = attributes.int64("unit_price") {
            return amount
        }
        if let amountDecimal = attributes.decimal("unit_price_decimal") {
            return NSDecimalNumber(decimal: amountDecimal).int64Value
        }
        if let firstTier = attributes.array("tiers")?.first {
            if let amount = firstTier.int64("unit_price") {
                return amount
            }
            if let amountDecimal = firstTier.decimal("unit_price_decimal") {
                return NSDecimalNumber(decimal: amountDecimal).int64Value
            }
        }
        return nil
    }

    private func parseUSDMinor(attributes: [String: Any]) -> Int64? {
        if let amount = attributes.int64("total_usd") {
            return amount
        }
        if let amount = attributes.int64("subtotal_usd") {
            return amount
        }
        if let amountMajor = attributes.decimal("total_usd") {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }
        if let amountMajor = attributes.decimal("subtotal_usd") {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }
        return nil
    }

    private func parseSubscriptionAmountMinor(attributes: [String: Any]) -> Int64? {
        if let firstItem = attributes.dictionary("first_subscription_item") {
            if let amount = firstItem.int64("price") {
                return amount
            }
            if let amount = firstItem.int64("unit_price") {
                return amount
            }
            if let decimal = firstItem.decimal("price") {
                return NSDecimalNumber(decimal: decimal * 100).int64Value
            }
        }

        if let amount = attributes.int64("variant_price") {
            return amount
        }
        if let amount = attributes.int64("subtotal") {
            return amount
        }
        if let amount = attributes.int64("total") {
            return amount
        }
        if let amountMajor = attributes.decimal("total_usd") {
            return NSDecimalNumber(decimal: amountMajor * 100).int64Value
        }

        return nil
    }

    private func parseInterval(attributes: [String: Any]) -> BillingInterval {
        let value = (
            attributes.string("billing_interval") ??
            attributes.string("renewal_interval_unit") ??
            attributes.string("interval") ??
            "month"
        ).lowercased()

        switch value {
        case "day", "daily":
            return .day
        case "week", "weekly":
            return .week
        case "year", "yearly", "annual":
            return .year
        default:
            return .month
        }
    }

    private func ensureSupportedCurrency(_ currency: String) throws {
        guard currency.uppercased() == supportedCurrency else {
            throw ProviderAdapterError.unsupported("RevenueBar is configured for USD only.")
        }
    }

    private func resolveUSDMinorUnits(
        sourceCurrency: String,
        defaultMinorUnits: Int64,
        usdFallbackMinorUnits: Int64?,
        context: String
    ) throws -> Int64 {
        let normalizedCurrency = sourceCurrency.uppercased()
        if normalizedCurrency == supportedCurrency {
            return defaultMinorUnits
        }
        if let usdFallbackMinorUnits {
            return usdFallbackMinorUnits
        }

        throw ProviderAdapterError.unsupported(
            "Encountered \(normalizedCurrency) in \(context). RevenueBar currently supports USD only."
        )
    }
}

private struct LemonSqueezyPriceContext {
    let amountMinorUnits: Int64
    let interval: BillingInterval
    let intervalCount: Int64
    let currencyCode: String?
}

private struct LemonSqueezyStoreMetrics {
    let totalRevenueMinorUnits: Int64
    let thirtyDayRevenueMinorUnits: Int64
}
