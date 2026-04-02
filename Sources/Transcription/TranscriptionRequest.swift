import Foundation

struct TranscriptionRequest {
    let audio: RecordedAudio
    let authToken: String
    let accountID: String?
    let baseURL: URL
    let userAgent: String

    func makeURLRequest() throws -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        let requestURL = normalizedBaseURL()
            .appendingPathComponent("transcribe")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let audioData = try Data(contentsOf: audio.fileURL)
        request.httpBody = multipartBody(boundary: boundary, audioData: audioData)
        return request
    }

    private func normalizedBaseURL() -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")!
    }

    private func multipartBody(boundary: String, audioData: Data) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
