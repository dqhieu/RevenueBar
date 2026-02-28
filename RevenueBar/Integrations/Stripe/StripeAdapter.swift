import Foundation

final class StripeAdapter: RevenueProviderAdapter {
    var provider: ProviderKind { .stripe }

    private let client: HTTPClient
    private let calendar: Calendar
    private let supportedCurrency = "USD"
    private let fxQuotePreviewVersion = "2025-07-30.preview"

    init(client: HTTPClient, calendar: Calendar = .current) {
        self.client = client
        self.calendar = calendar
    }

    func validateKey(_ key: String) async throws {
        _ = try await fetchAccount(key: key)
    }

    func listSelectableEntities(using key: String) async throws -> [ProviderEntity] {
        let account = try await fetchAccount(key: key)
        let name = account.businessProfile?.name ?? account.company?.name ?? account.id
        return [ProviderEntity(id: account.id, name: name)]
    }

    func fetchRevenueSnapshot(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> ProviderRevenueSnapshot {
        try ensureSupportedCurrency(currency)
        let events = try await fetchRevenueEvents(key: key)
        return AdapterSupport.grossSnapshot(events: events, currency: currency, now: now, calendar: calendar)
    }

    func fetchMrr(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> MonetaryAmount {
        try ensureSupportedCurrency(currency)
        let subscriptions = try await fetchActiveSubscriptions(key: key)
        var pendingItems: [PendingSubscriptionItem] = []
        var sourceCurrencies = Set<String>()

        for subscription in subscriptions {
            for item in subscription.items.data {
                guard
                    let unitAmount = item.price.unitAmount,
                    let priceCurrency = item.price.currency,
                    let recurring = item.price.recurring
                else {
                    continue
                }

                let normalizedCurrency = priceCurrency.uppercased()
                sourceCurrencies.insert(normalizedCurrency)

                pendingItems.append(PendingSubscriptionItem(
                    amountMinorUnits: Int64(unitAmount),
                    sourceCurrency: normalizedCurrency,
                    interval: BillingInterval(rawValue: recurring.interval) ?? .month,
                    intervalCount: recurring.intervalCount,
                    quantity: item.quantity ?? 1
                ))
            }
        }

        let usdRates = try await fetchUSDRates(for: sourceCurrencies, key: key)
        var mrrMinorUnits: Int64 = 0

        for item in pendingItems {
                let usdAmount = try convertToUSD(
                    minorUnits: item.amountMinorUnits,
                    sourceCurrency: item.sourceCurrency,
                    usdRates: usdRates,
                    context: "Stripe subscription price"
                )

                let normalized = AdapterSupport.normalizedMonthlyMinorUnits(for: RecurringRevenueItem(
                    amount: usdAmount,
                    interval: item.interval,
                    intervalCount: item.intervalCount,
                    quantity: item.quantity
                ))
                mrrMinorUnits += normalized
        }

        return MonetaryAmount(minorUnits: mrrMinorUnits, currencyCode: currency)
    }

    private func fetchAccount(key: String) async throws -> StripeAccount {
        var request = URLRequest(url: URL(string: "https://api.stripe.com/v1/account")!)
        request.httpMethod = "GET"
        request.setBasicAuth(username: key)
        let response = try await client.send(request)
        return try JSONDecoder().decode(StripeAccount.self, from: response.data)
    }

    private func fetchRevenueEvents(key: String) async throws -> [RevenueEvent] {
        var pendingEvents: [PendingRevenueEvent] = []
        var sourceCurrencies = Set<String>()
        var hasMore = true
        var startingAfter: String?
        var pages = 0
        let maxPages = 100

        while hasMore && pages < maxPages {
            var components = URLComponents(string: "https://api.stripe.com/v1/balance_transactions")!
            var queryItems = [
                URLQueryItem(name: "limit", value: "100")
            ]
            if let startingAfter {
                queryItems.append(URLQueryItem(name: "starting_after", value: startingAfter))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setBasicAuth(username: key)

            let response = try await client.send(request)
            let parsed = try JSONDecoder().decode(StripeListResponse<StripeBalanceTransaction>.self, from: response.data)

            for row in parsed.data {
                guard row.amount > 0 else { continue }
                let normalizedCurrency = row.currency.uppercased()
                sourceCurrencies.insert(normalizedCurrency)
                pendingEvents.append(PendingRevenueEvent(
                    createdAt: row.created,
                    amountMinorUnits: Int64(row.amount),
                    sourceCurrency: normalizedCurrency
                ))
            }

            hasMore = parsed.hasMore
            startingAfter = parsed.data.last?.id
            pages += 1
        }

        let usdRates = try await fetchUSDRates(for: sourceCurrencies, key: key)
        var events: [RevenueEvent] = []
        events.reserveCapacity(pendingEvents.count)

        for event in pendingEvents {
            let usdAmount = try convertToUSD(
                minorUnits: event.amountMinorUnits,
                sourceCurrency: event.sourceCurrency,
                usdRates: usdRates,
                context: "Stripe balance transaction"
            )

            events.append(RevenueEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(event.createdAt)),
                amount: usdAmount
            ))
        }

        return events
    }

    private func fetchActiveSubscriptions(key: String) async throws -> [StripeSubscription] {
        var subscriptions: [StripeSubscription] = []
        var hasMore = true
        var startingAfter: String?
        var pages = 0
        let maxPages = 100

        while hasMore && pages < maxPages {
            var components = URLComponents(string: "https://api.stripe.com/v1/subscriptions")!
            var queryItems = [
                URLQueryItem(name: "status", value: "active"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "expand[]", value: "data.items.data.price")
            ]
            if let startingAfter {
                queryItems.append(URLQueryItem(name: "starting_after", value: startingAfter))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setBasicAuth(username: key)
            let response = try await client.send(request)
            let parsed = try JSONDecoder().decode(StripeListResponse<StripeSubscription>.self, from: response.data)
            subscriptions.append(contentsOf: parsed.data)

            hasMore = parsed.hasMore
            startingAfter = parsed.data.last?.id
            pages += 1
        }

        return subscriptions
    }

    private func fetchUSDRates(for sourceCurrencies: Set<String>, key: String) async throws -> [String: Decimal] {
        let normalizedCurrencies = Set(sourceCurrencies.map { $0.uppercased() }).subtracting([supportedCurrency])
        guard !normalizedCurrencies.isEmpty else { return [:] }

        var ratesByCurrency: [String: Decimal] = [:]

        if let fxQuoteRates = try? await fetchUSDRatesFromFXQuotes(fromCurrencies: normalizedCurrencies, key: key) {
            ratesByCurrency.merge(fxQuoteRates, uniquingKeysWith: { current, _ in current })
        }

        var missingCurrencies = normalizedCurrencies.subtracting(Set(ratesByCurrency.keys))
        if !missingCurrencies.isEmpty,
           let legacyRates = try? await fetchUSDRatesFromLegacyStripe(key: key) {
            for currency in missingCurrencies where ratesByCurrency[currency] == nil {
                if let rate = legacyRates[currency] {
                    ratesByCurrency[currency] = rate
                }
            }
        }

        missingCurrencies = normalizedCurrencies.subtracting(Set(ratesByCurrency.keys))
        if !missingCurrencies.isEmpty,
           let fallbackRates = try? await fetchUSDRatesFromFrankfurter() {
            for currency in missingCurrencies where ratesByCurrency[currency] == nil {
                if let rate = fallbackRates[currency] {
                    ratesByCurrency[currency] = rate
                }
            }
        }

        return ratesByCurrency
    }

    private func fetchUSDRatesFromFXQuotes(fromCurrencies: Set<String>, key: String) async throws -> [String: Decimal] {
        var request = URLRequest(url: URL(string: "https://api.stripe.com/v1/fx_quotes")!)
        request.httpMethod = "POST"
        request.setBasicAuth(username: key)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(fxQuotePreviewVersion, forHTTPHeaderField: "Stripe-Version")

        var queryItems = [
            URLQueryItem(name: "to_currency", value: supportedCurrency.lowercased()),
            URLQueryItem(name: "lock_duration", value: "none")
        ]
        queryItems.append(contentsOf: fromCurrencies.sorted().map {
            URLQueryItem(name: "from_currencies[]", value: $0.lowercased())
        })

        var components = URLComponents()
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let response = try await client.send(request)
        let payload = try JSONDecoder().decode(StripeFXQuoteResponse.self, from: response.data)

        var ratesByCurrency: [String: Decimal] = [:]
        for (currency, quoteRate) in payload.rates {
            if let baseRate = quoteRate.rateDetails?.baseRate, baseRate > 0 {
                ratesByCurrency[currency.uppercased()] = baseRate
            } else if let exchangeRate = quoteRate.exchangeRate, exchangeRate > 0 {
                ratesByCurrency[currency.uppercased()] = exchangeRate
            }
        }

        return ratesByCurrency
    }

    private func fetchUSDRatesFromLegacyStripe(key: String) async throws -> [String: Decimal] {
        do {
            var request = URLRequest(url: URL(string: "https://api.stripe.com/v1/exchange_rates/usd")!)
            request.httpMethod = "GET"
            request.setBasicAuth(username: key)
            let response = try await client.send(request)
            let payload = try JSONDecoder().decode(StripeExchangeRatesResponse.self, from: response.data)
            return payload.rates.reduce(into: [:]) { partialResult, entry in
                partialResult[entry.key.uppercased()] = entry.value
            }
        }
    }

    private func fetchUSDRatesFromFrankfurter() async throws -> [String: Decimal] {
        var request = URLRequest(url: URL(string: "https://api.frankfurter.app/latest?from=USD")!)
        request.httpMethod = "GET"
        let response = try await client.send(request)
        let payload = try JSONDecoder().decode(FrankfurterRatesResponse.self, from: response.data)
        return payload.rates.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key.uppercased()] = entry.value
        }
    }

    private func ensureSupportedCurrency(_ currency: String) throws {
        guard currency.uppercased() == supportedCurrency else {
            throw ProviderAdapterError.unsupported("RevenueBar is configured for USD only.")
        }
    }

    private func convertToUSD(
        minorUnits: Int64,
        sourceCurrency: String,
        usdRates: [String: Decimal],
        context: String
    ) throws -> MonetaryAmount {
        let normalizedCurrency = sourceCurrency.uppercased()
        if normalizedCurrency == supportedCurrency {
            return MonetaryAmount(minorUnits: minorUnits, currencyCode: supportedCurrency)
        }

        guard let usdToSourceRate = usdRates[normalizedCurrency], usdToSourceRate > 0 else {
            throw ProviderAdapterError.unsupported(
                "Encountered \(normalizedCurrency) in \(context). RevenueBar could not convert it to USD because Stripe exchange rate is unavailable."
            )
        }

        let sourceScale = minorUnitScale(for: normalizedCurrency)
        let sourceMajorAmount = Decimal(minorUnits) / decimalPower10(sourceScale)
        let usdMajorAmount = sourceMajorAmount / usdToSourceRate
        let usdMinorUnits = roundedMinorUnits(amountMajor: usdMajorAmount, currency: supportedCurrency)

        return MonetaryAmount(minorUnits: usdMinorUnits, currencyCode: supportedCurrency)
    }

    private func minorUnitScale(for currency: String) -> Int {
        let zeroDecimalCurrencies: Set<String> = [
            "BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG",
            "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"
        ]
        let threeDecimalCurrencies: Set<String> = ["BHD", "JOD", "KWD", "OMR", "TND"]

        if zeroDecimalCurrencies.contains(currency) {
            return 0
        }
        if threeDecimalCurrencies.contains(currency) {
            return 3
        }
        return 2
    }

    private func decimalPower10(_ exponent: Int) -> Decimal {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(Decimal(1)) { partialResult, _ in
            partialResult * 10
        }
    }

    private func roundedMinorUnits(amountMajor: Decimal, currency: String) -> Int64 {
        let minorScale = minorUnitScale(for: currency)
        var scaled = amountMajor * decimalPower10(minorScale)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .bankers)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

private struct StripeListResponse<T: Decodable>: Decodable {
    let data: [T]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }
}

private struct StripeAccount: Decodable {
    struct BusinessProfile: Decodable {
        let name: String?
    }

    struct Company: Decodable {
        let name: String?
    }

    let id: String
    let businessProfile: BusinessProfile?
    let company: Company?

    private enum CodingKeys: String, CodingKey {
        case id
        case businessProfile = "business_profile"
        case company
    }
}

private struct StripeBalanceTransaction: Decodable {
    let id: String
    let amount: Int
    let currency: String
    let created: Int
}

private struct StripeExchangeRatesResponse: Decodable {
    let rates: [String: Decimal]
}

private struct FrankfurterRatesResponse: Decodable {
    let rates: [String: Decimal]
}

private struct StripeFXQuoteResponse: Decodable {
    let rates: [String: StripeFXQuoteRate]
}

private struct StripeFXQuoteRate: Decodable {
    let exchangeRate: Decimal?
    let rateDetails: StripeFXQuoteRateDetails?

    private enum CodingKeys: String, CodingKey {
        case exchangeRate = "exchange_rate"
        case rateDetails = "rate_details"
    }
}

private struct StripeFXQuoteRateDetails: Decodable {
    let baseRate: Decimal?

    private enum CodingKeys: String, CodingKey {
        case baseRate = "base_rate"
    }
}

private struct PendingRevenueEvent {
    let createdAt: Int
    let amountMinorUnits: Int64
    let sourceCurrency: String
}

private struct PendingSubscriptionItem {
    let amountMinorUnits: Int64
    let sourceCurrency: String
    let interval: BillingInterval
    let intervalCount: Int
    let quantity: Int
}

private struct StripeSubscription: Decodable {
    struct Items: Decodable {
        let data: [Item]
    }

    struct Item: Decodable {
        struct Price: Decodable {
            struct Recurring: Decodable {
                let interval: String
                let intervalCount: Int

                private enum CodingKeys: String, CodingKey {
                    case interval
                    case intervalCount = "interval_count"
                }
            }

            let unitAmount: Int?
            let currency: String?
            let recurring: Recurring?

            private enum CodingKeys: String, CodingKey {
                case unitAmount = "unit_amount"
                case currency
                case recurring
            }
        }

        let quantity: Int?
        let price: Price
    }

    let id: String
    let items: Items
}
