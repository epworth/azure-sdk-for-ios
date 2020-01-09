// --------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//
// The MIT License (MIT)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the ""Software""), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// --------------------------------------------------------------------------

import Foundation

public class LoggingPolicy: PipelineStageProtocol {

    public static let defaultAllowHeaders: [String] = [
        HttpHeader.traceparent.rawValue,
        HttpHeader.accept.rawValue,
        HttpHeader.cacheControl.rawValue,
        HttpHeader.clientRequestId.rawValue,
        HttpHeader.connection.rawValue,
        HttpHeader.contentLength.rawValue,
        HttpHeader.contentType.rawValue,
        HttpHeader.date.rawValue,
        HttpHeader.etag.rawValue,
        HttpHeader.expires.rawValue,
        HttpHeader.ifMatch.rawValue,
        HttpHeader.ifModifiedSince.rawValue,
        HttpHeader.ifNoneMatch.rawValue,
        HttpHeader.ifUnmodifiedSince.rawValue,
        HttpHeader.lastModified.rawValue,
        HttpHeader.pragma.rawValue,
        HttpHeader.requestId.rawValue,
        HttpHeader.retryAfter.rawValue,
        HttpHeader.returnClientRequestId.rawValue,
        HttpHeader.server.rawValue,
        HttpHeader.transferEncoding.rawValue,
        HttpHeader.userAgent.rawValue
    ]
    private static let maxBodyLogSize = 1024 * 16

    public var next: PipelineStageProtocol?
    private let allowHeaders: Set<String>
    private let allowQueryParams: Set<String>

    public init(allowHeaders: [String] = LoggingPolicy.defaultAllowHeaders, allowQueryParams: [String] = []) {
        self.allowHeaders = Set(allowHeaders.map { $0.lowercased() })
        self.allowQueryParams = Set(allowQueryParams.map { $0.lowercased() })
    }

    public func onRequest(_ request: PipelineRequest, then completion: @escaping OnRequestCompletionHandler) {
        var returnRequest = request.copy()
        let logger = request.logger
        let req = request.httpRequest
        let requestId = req.headers[.clientRequestId] ?? "(none)"
        guard
            let safeUrl = self.redact(url: req.url),
            let host = safeUrl.host
        else {
            logger.warning("Failed to parse URL for request \(requestId)")
            return
        }

        var fullPath = safeUrl.path
        if let query = safeUrl.query {
            fullPath += "?\(query)"
        }
        if let fragment = safeUrl.fragment {
            fullPath += "#\(fragment)"
        }

        logger.info("--> [\(requestId)]")
        logger.info("\(req.httpMethod.rawValue) \(fullPath)")
        logger.info("Host: \(host)")

        if logger.level.rawValue >= ClientLogLevel.debug.rawValue {
            logDebug(body: req.text(), headers: req.headers, logger: logger)
        }

        logger.info("--> [END \(requestId)]")

        returnRequest.add(value: DispatchTime.now() as AnyObject, forKey: .requestStartTime)
        completion(returnRequest)
    }

    public func onResponse(_ response: PipelineResponse, then completion: @escaping OnResponseCompletionHandler) {
        logResponse(response)
        completion(response)
    }

    public func onError(_ error: PipelineError, then completion: @escaping OnErrorCompletionHandler) {
        logResponse(error.pipelineResponse, withError: error.innerError)
        completion(error, false)
    }

    private func logResponse(_ response: PipelineResponse, withError error: Error? = nil) {
        let endTime = DispatchTime.now()
        var durationMs: Double?
        if let startTime = response.value(forKey: .requestStartTime) as? DispatchTime {
            durationMs = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        }

        let logger = response.logger
        let req = response.httpRequest
        let requestId = req.headers[.clientRequestId] ?? "(none)"

        if let durationMs = durationMs {
            logger.info("<-- [\(requestId)] (\(durationMs)ms)")
        } else {
            logger.info("<-- [\(requestId)]")
        }

        if let error = error {
            logger.warning(error.localizedDescription)
        }

        guard
            let res = response.httpResponse,
            let statusCode = res.statusCode
        else {
            logger.warning("No response data available")
            logger.info("<-- [END \(requestId)]")
            return
        }

        let statusCodeString = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if statusCode >= 400 {
            logger.warning("\(statusCode) \(statusCodeString)")
        } else {
            logger.info("\(statusCode) \(statusCodeString)")
        }

        if logger.level.rawValue >= ClientLogLevel.debug.rawValue {
            logDebug(body: res.text(), headers: res.headers, logger: logger)
        }

        logger.info("<-- [END \(requestId)]")
    }

    private func logDebug(body bodyFunc: @autoclosure () -> String?, headers: HttpHeaders, logger: ClientLogger) {
        let safeHeaders = self.redact(headers: headers)
        for (header, value) in safeHeaders {
            logger.debug("\(header): \(value)")
        }

        let bodyText = self.humanReadable(body: bodyFunc, headers: headers)
        logger.debug("\n\(bodyText)")
    }

    private func humanReadable(body bodyFunc: () -> String?, headers: HttpHeaders) -> String {
        if
            let encoding = headers[.contentEncoding],
            encoding != "" && encoding.caseInsensitiveCompare("identity") != .orderedSame {
            return "(encoded body omitted)"
        }

        if
            let disposition = headers[.contentDisposition],
            disposition != "" && disposition.caseInsensitiveCompare("inline") != .orderedSame {
            return "(non-inline body omitted)"
        }

        if
            let contentType = headers[.contentType],
            contentType.lowercased().hasSuffix("octet-stream") || contentType.lowercased().hasPrefix("image") {
            return "(binary body omitted)"
        }

        let length = contentLength(from: headers)
        if length > LoggingPolicy.maxBodyLogSize {
            return "(\(length)-byte body omitted)"
        }

        if length > 0 {
            if let text = bodyFunc(), text != "" {
                return text
            }
        }
        return "(empty body)"
    }

    private func redact(url: String) -> URLComponents? {
        guard var urlComps = URLComponents(string: url) else { return nil }
        guard let queryItems = urlComps.queryItems else { return urlComps }

        var redactedQueryItems = [URLQueryItem]()
        for query in queryItems {
            if !self.allowQueryParams.contains(query.name.lowercased()) {
                redactedQueryItems.append(URLQueryItem(name: query.name, value: "REDACTED"))
            } else {
                redactedQueryItems.append(query)
            }
        }

        urlComps.queryItems = redactedQueryItems
        return urlComps
    }

    private func redact(headers: HttpHeaders) -> HttpHeaders {
        var copy = headers
        for header in copy.keys {
            if !self.allowHeaders.contains(header.lowercased()) {
                copy.updateValue("REDACTED", forKey: header)
            }
        }
        return copy
    }

    private func contentLength(from headers: HttpHeaders) -> Int {
        guard let length = headers[.contentLength] else { return 0 }
        guard let parsed = Int(length) else { return 0 }
        return parsed
    }
}

public class CurlFormattedRequestLoggingPolicy: PipelineStageProtocol {
    public var next: PipelineStageProtocol?

    public init() {}

    public func onRequest(_ request: PipelineRequest, then completion: @escaping OnRequestCompletionHandler) {
        let logger = request.logger
        guard logger.level.rawValue >= ClientLogLevel.debug.rawValue else { return }

        let req = request.httpRequest
        var compressed = false
        var parts = ["curl"]
        parts += ["-X", req.httpMethod.rawValue]
        for (header, value) in req.headers {
            var escapedValue: String
            if value.first == "\"" && value.last == "\"" {
                // Escape the surrounding quote marks and literal backslashes
                var innerValue = value.trimmingCharacters(in: ["\""])
                innerValue = innerValue.replacingOccurrences(of: "\\", with: "\\\\")
                escapedValue = "\\\"\(innerValue)\\\""
            } else {
                // Only escape literal backslashes
                escapedValue = value.replacingOccurrences(of: "\\", with: "\\\\")
            }

            if header == HttpHeader.acceptEncoding.rawValue {
                compressed = true
            }

            parts += ["-H", "\"\(header): \(escapedValue)\""]
        }
        if var bodyText = req.text() {
            // Escape literal newlines and single quotes in the body
            bodyText = bodyText.replacingOccurrences(of: "\n", with: "\\n")
            bodyText = bodyText.replacingOccurrences(of: "'", with: "\\'")
            parts += ["--data", "$'\(bodyText)'"]
        }
        if compressed {
            parts.append("--compressed")
        }
        parts.append(req.url)

        logger.debug("╭--- cURL (\(req.url))")
        logger.debug(parts.joined(separator: " "))
        logger.debug("╰--- (copy and paste the above line to a terminal)")
        completion(request)
    }
}