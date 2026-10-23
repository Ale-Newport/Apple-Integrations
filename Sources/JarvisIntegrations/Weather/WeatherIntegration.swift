import Foundation
import JarvisCore

public protocol WeatherDataLoading: Sendable {
    func load(_ url: URL) async throws -> JSONValue
}

public struct WeatherURLLoader: WeatherDataLoading {
    public init() {}
    public func load(_ url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 512_000 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Provider-neutral data loading and a small in-memory cache; no location permission or polling.
public actor WeatherCache {
    private var entries: [URL: (Date, JSONValue)] = [:]
    private let loader: any WeatherDataLoading
    public init(loader: any WeatherDataLoading = WeatherURLLoader()) { self.loader = loader }
    func load(_ url: URL, now: Date) async throws -> JSONValue {
        if let (date, value) = entries[url], now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < 600 { return value }
        let value: JSONValue
        do { value = try await loader.load(url) }
        catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
            try await Task.sleep(for: .milliseconds(200))
            value = try await loader.load(url)
        }
        entries[url] = (now, value)
        if entries.count > 32, let key = entries.keys.first(where: { $0 != url }) { entries[key] = nil }
        return value
    }
}

public struct WeatherIntegration: AppIntegration {
    public let id: IntegrationID = "weather"
    public let displayName = LocalizedText(en: "Weather", es: "Tiempo")
    public let summary = LocalizedText(en: "Current conditions and daily forecasts from Open-Meteo. Network required; no background monitoring.", es: "Condiciones actuales y previsiones diarias de Open-Meteo. Requiere conexión; sin seguimiento en segundo plano.")
    public let symbolName = "cloud.sun"
    public let permissionRequirements: [PermissionRequirement] = []
    private let cache: WeatherCache
    public init(cache: WeatherCache = WeatherCache()) { self.cache = cache }
    public var tools: [ToolDescriptor] { [ToolDescriptor(name: "weather.forecast", integration: id, title: "Weather forecast", summary: "Real current weather and daily forecast (up to 7 days). Specify a place or use the configured default. Resolve ambiguous cities with place_id from the offered options. No severe alerts, persistent conditions or location tracking.", parameters: [
        .string("location", "City, optionally with country after comma.", maxLength: 200),
        .date("date", "Forecast day; omitted means current and upcoming days."),
        .integer("place_id", "Exact place ID from a clarification.", min: 1)
    ], safety: .readOnly, timeout: 40)] }
    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready, detail: LocalizedText(en: "Open-Meteo · internet required", es: "Open-Meteo · requiere internet")) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        guard let location = call.string("location") ?? context.settings.weatherLocation, !location.isEmpty else {
            return .clarify(Clarification(question: context.language.pick("Which city should I check? Set a default in Intelligence settings.", "¿Qué ciudad consulto? Puedes guardar una ubicación en los ajustes de Inteligencia.")))
        }
        do {
            var geocode = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            geocode.queryItems = [URLQueryItem(name: "name", value: location), URLQueryItem(name: "count", value: "5"), URLQueryItem(name: "language", value: context.language.rawValue)]
            let found = try await cache.load(geocode.url!, now: context.now)
            let places = found["results"]?.arrayValue ?? []
            guard !places.isEmpty else { throw JarvisError.notFound("place_not_found", en: "No matching city was found.", es: "No se encontró esa ciudad.") }
            let chosen: JSONValue
            if let id = call.int("place_id") {
                guard let match = places.first(where: { $0["id"]?.intValue == id }) else { throw URLError(.cannotParseResponse) }
                chosen = match
            } else if places.count == 1 || (places[0]["population"]?.intValue ?? 0) > max(1, places.dropFirst().map { $0["population"]?.intValue ?? 0 }.max() ?? 0) * 5 {
                chosen = places[0]
            } else {
                let options = places.compactMap { place -> ClarificationOption? in
                    guard let id = place["id"]?.intValue, let name = place["name"]?.stringValue else { return nil }
                    return ClarificationOption(label: name, detail: [place["admin1"]?.stringValue, place["country"]?.stringValue].compactMap { $0 }.joined(separator: ", "), call: call.call.adding(["location": .string(location), "place_id": .int(id)]))
                }
                return .clarify(Clarification(question: context.language.pick("Which location?", "¿Qué ubicación?"), options: options))
            }
            guard let latitude = chosen["latitude"]?.doubleValue, let longitude = chosen["longitude"]?.doubleValue,
                  let name = chosen["name"]?.stringValue else { throw URLError(.cannotParseResponse) }
            var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            forecast.queryItems = [
                URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "7"),
                URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
                URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max,sunrise,sunset")
            ]
            let value = try await cache.load(forecast.url!, now: context.now)
            guard let days = value["daily"]?["time"]?.arrayValue, !days.isEmpty else { throw URLError(.cannotParseResponse) }
            var indices = Array(days.indices)
            if let day = call.string("date") {
                indices = days.indices.filter { days[$0].stringValue == day }
                guard !indices.isEmpty else { throw JarvisError.failed("forecast_range", en: "That date is outside the available seven-day forecast.", es: "Esa fecha está fuera de la previsión disponible de siete días.") }
            }
            var rows: [JSONValue] = []
            var lines: [String] = []
            for index in indices {
                guard let day = days[index].stringValue,
                      let low = value["daily"]?["temperature_2m_min"]?[index]?.doubleValue,
                      let high = value["daily"]?["temperature_2m_max"]?[index]?.doubleValue,
                      let rain = value["daily"]?["precipitation_probability_max"]?[index]?.doubleValue else { throw URLError(.cannotParseResponse) }
                var row: JSONObject = ["date": .string(day), "min_c": .double(low), "max_c": .double(high), "rain_probability_percent": .double(rain)]
                row["sunrise"] = value["daily"]?["sunrise"]?[index]
                row["sunset"] = value["daily"]?["sunset"]?[index]
                row["uv_index_max"] = value["daily"]?["uv_index_max"]?[index]
                rows.append(.object(row))
                lines.append("\(day): \(low)–\(high) °C · " + context.language.pick("rain", "lluvia") + " \(rain)%")
            }
            if call.string("date") == nil, let temperature = value["current"]?["temperature_2m"]?.doubleValue {
                lines.insert(context.language.pick("Now", "Ahora") + ": \(temperature) °C", at: 0)
            }
            let country = chosen["country"]?.stringValue ?? ""
            let data: JSONObject = ["location": .string("\(name), \(country)"), "timezone": value["timezone"] ?? .null,
                "current": value["current"] ?? .null, "days": .array(rows), "source": "https://open-meteo.com/", "attribution": "Weather data by Open-Meteo · CC BY 4.0; geocoding by GeoNames"]
            return .done(ToolOutput(message: "\(name), \(country)\n" + lines.joined(separator: "\n") + "\nOpen-Meteo · https://open-meteo.com/", data: .object(data), verification: .verified(context.language.pick("Retrieved from Open-Meteo; cached for at most ten minutes.", "Datos de Open-Meteo; caché de hasta diez minutos."))))
        } catch is CancellationError { throw CancellationError() }
        catch let error as JarvisError { throw error }
        catch { throw JarvisError.failed("weather_unavailable", en: "Weather data could not be retrieved. Check your connection and try again.", es: "No se pudieron obtener los datos meteorológicos. Revisa la conexión e inténtalo de nuevo.") }
    }
}
