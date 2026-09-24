import Foundation

/// Minimal client for TypeSafe's System One endpoint (Jev).
struct Jev {
    struct Answer {
        let choice: String?
        let confidence: Double?
        let noul: Double?
        let probabilities: [String: Double]

        /// Probability of the chosen option (stable across option counts, unlike confidence).
        var topProbability: Double { choice.flatMap { probabilities[$0] } ?? 0 }
    }

    enum JevError: Error, LocalizedError {
        case missingKey
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: return "TYPESAFE_API_KEY not set (~/.config/cursorboy/env)"
            case .http(let code, let body): return "Jev HTTP \(code): \(body.prefix(200))"
            case .badResponse: return "Jev returned an unexpected response"
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Evaluates `questions` (already in API shape) against `state`.
    static func ask(state: Any, questions: [String: Any]) async throws -> [String: Answer] {
        guard let key = Config.typesafeKey else { throw JevError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "state": state,
            "model": "jev-latest",
            "questions": questions,
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JevError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: [String: Any]] else {
            throw JevError.badResponse
        }
        return answers.mapValues { raw in
            Answer(
                choice: raw["choice"] as? String,
                confidence: (raw["confidence"] as? NSNumber)?.doubleValue,
                noul: (raw["noul"] as? NSNumber)?.doubleValue,
                probabilities: ((raw["probabilities"] as? [String: NSNumber]) ?? [:]).mapValues(\.doubleValue)
            )
        }
    }

    static func choice(_ instructions: Any, _ criteria: [String: Any]) -> [String: Any] {
        ["type": "choice", "instructions": instructions, "criteria": criteria]
    }

    static func noul(_ instructions: Any, yes: String, no: String) -> [String: Any] {
        ["type": "noul", "instructions": instructions, "criteria": ["true": yes, "false": no]]
    }
}
