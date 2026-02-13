import Foundation

/// Service for Google Drive, Docs, Sheets, and Slides API operations.
/// Uses connected account tokens for authentication.
actor GoogleDriveToolService {

    /// Shared singleton instance
    static let shared = GoogleDriveToolService()

    /// Connected accounts service for token management
    private let accountsService = ConnectedAccountsService.shared

    private init() {}

    // MARK: - HTTP Helpers

    /// Make an authenticated request to Google APIs
    private func request(
        method: String,
        url: URL,
        accountId: String,
        queryParams: [String: String]? = nil,
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 20.0
    ) async throws -> (Data, HTTPURLResponse) {
        // Get access token (will refresh if expired)
        let accessToken = try await accountsService.getAccessToken(forAccountId: accountId)

        // Build URL with query params
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let queryParams {
            let existingItems = components.queryItems ?? []
            components.queryItems = existingItems + queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let finalURL = components.url else {
            throw GoogleDriveError.invalidURL
        }

        // Build request
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }

        // Execute request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }

        // Handle 401 by marking account for re-auth
        if httpResponse.statusCode == 401 {
            throw GoogleDriveError.unauthorized(message: "Google token expired or revoked. Please reconnect your Google account.")
        }

        return (data, httpResponse)
    }

    /// Parse Google API error
    private func parseError(statusCode: Int, data: Data) -> GoogleDriveError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return .apiError(statusCode: statusCode, message: message)
        }
        return .apiError(statusCode: statusCode, message: String(data: data, encoding: .utf8) ?? "Unknown error")
    }

    // MARK: - Drive Operations

    /// List files from Google Drive
    func listFiles(
        accountId: String,
        query: String? = nil,
        pageSize: Int = 50,
        pageToken: String? = nil
    ) async throws -> DriveListResponse {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files")!

        var params: [String: String] = [
            "pageSize": String(min(pageSize, 100)),
            "fields": "files(id,name,mimeType,modifiedTime,owners,iconLink,webViewLink),nextPageToken"
        ]
        if let query { params["q"] = query }
        if let pageToken { params["pageToken"] = pageToken }

        let (data, response) = try await request(
            method: "GET",
            url: url,
            accountId: accountId,
            queryParams: params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        return try JSONDecoder().decode(DriveListResponse.self, from: data)
    }

    /// Download file contents from Google Drive
    /// For Google Docs/Sheets/Slides, use mimeType to export in desired format
    func downloadFile(
        accountId: String,
        fileId: String,
        exportMimeType: String? = nil
    ) async throws -> Data {
        let url: URL
        var params: [String: String] = [:]

        if let exportMimeType {
            // Use export endpoint for Google Workspace files
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/export")!
            params["mimeType"] = exportMimeType
        } else {
            // Use direct download for binary files
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
            params["alt"] = "media"
        }

        let (data, response) = try await request(
            method: "GET",
            url: url,
            accountId: accountId,
            queryParams: params,
            timeout: 60.0
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        return data
    }

    /// Upload a file to Google Drive
    func uploadFile(
        accountId: String,
        name: String,
        mimeType: String,
        content: Data,
        parentFolderId: String? = nil
    ) async throws -> DriveFile {
        // Build multipart upload
        let boundary = "================AICovenDriveBoundary=="

        var metadata: [String: Any] = ["name": name, "mimeType": mimeType]
        if let parentFolderId {
            metadata["parents"] = [parentFolderId]
        }

        let metadataJson = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataJson)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!

        let (data, response) = try await request(
            method: "POST",
            url: url,
            accountId: accountId,
            body: body,
            contentType: "multipart/related; boundary=\(boundary)",
            timeout: 60.0
        )

        if response.statusCode != 200, response.statusCode != 201 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    /// Get file metadata
    func getFile(accountId: String, fileId: String) async throws -> DriveFile {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        let params = ["fields": "id,name,mimeType,modifiedTime,owners,webViewLink,size"]

        let (data, response) = try await request(
            method: "GET",
            url: url,
            accountId: accountId,
            queryParams: params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    // MARK: - Google Docs Operations

    /// Read a Google Doc with full structure
    func readDocument(accountId: String, documentId: String) async throws -> [String: Any] {
        let url = URL(string: "https://docs.googleapis.com/v1/documents/\(documentId)")!

        let (data, response) = try await request(
            method: "GET",
            url: url,
            accountId: accountId
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleDriveError.invalidResponse
        }

        return json
    }

    /// Get plain text content of a Google Doc
    func readDocumentText(accountId: String, documentId: String) async throws -> String {
        // Export as plain text
        let data = try await downloadFile(
            accountId: accountId,
            fileId: documentId,
            exportMimeType: "text/plain"
        )

        guard let text = String(data: data, encoding: .utf8) else {
            throw GoogleDriveError.decodingFailed
        }

        return text
    }

    // MARK: - Google Sheets Operations

    /// Read spreadsheet metadata
    func readSpreadsheet(accountId: String, spreadsheetId: String) async throws -> [String: Any] {
        let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)")!

        let (data, response) = try await request(
            method: "GET",
            url: url,
            accountId: accountId
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleDriveError.invalidResponse
        }

        return json
    }

    /// Read values from a spreadsheet range
    func readSpreadsheetValues(
        accountId: String,
        spreadsheetId: String,
        range: String
    ) async throws -> [[String]] {
        let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(range)")!

        let (data, response) = try await request(
            method: "GET",
            url: url,
            accountId: accountId
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["values"] as? [[Any]] else {
            return [] // Empty range returns no values
        }

        // Convert all values to strings
        return values.map { row in
            row.map { String(describing: $0) }
        }
    }

    /// Write values to a spreadsheet range
    func writeSpreadsheetValues(
        accountId: String,
        spreadsheetId: String,
        range: String,
        values: [[String]],
        inputOption: String = "USER_ENTERED"
    ) async throws -> [String: Any] {
        let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(range)")!
        let params = ["valueInputOption": inputOption]

        let body: [String: Any] = [
            "range": range,
            "majorDimension": "ROWS",
            "values": values
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await request(
            method: "PUT",
            url: url,
            accountId: accountId,
            queryParams: params,
            body: bodyData
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleDriveError.invalidResponse
        }

        return json
    }

    /// Append values to a spreadsheet
    func appendSpreadsheetValues(
        accountId: String,
        spreadsheetId: String,
        range: String,
        values: [[String]],
        inputOption: String = "USER_ENTERED"
    ) async throws -> [String: Any] {
        let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(range):append")!
        let params = ["valueInputOption": inputOption, "insertDataOption": "INSERT_ROWS"]

        let body: [String: Any] = [
            "range": range,
            "majorDimension": "ROWS",
            "values": values
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await request(
            method: "POST",
            url: url,
            accountId: accountId,
            queryParams: params,
            body: bodyData
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleDriveError.invalidResponse
        }

        return json
    }
}

// MARK: - Response Types

/// Response from Drive files.list API
struct DriveListResponse: Codable {
    let files: [DriveFile]
    let nextPageToken: String?
}

/// Google Drive file metadata
struct DriveFile: Codable {
    let id: String
    let name: String
    let mimeType: String?
    let modifiedTime: String?
    let webViewLink: String?
    let iconLink: String?
    let size: String?
}

// MARK: - Errors

/// Errors that can occur during Google Drive API operations
enum GoogleDriveError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized(message: String)
    case apiError(statusCode: Int, message: String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid Google API URL"
        case .invalidResponse:
            "Invalid response from Google API"
        case let .unauthorized(message):
            "Google unauthorized: \(message)"
        case let .apiError(statusCode, message):
            "Google API error (\(statusCode)): \(message)"
        case .decodingFailed:
            "Failed to decode Google API response"
        }
    }
}
