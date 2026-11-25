//
//  CachedDownload.swift
//  patcher
//
//  Small hosted data files (tracker data, label lists) fetched with ETag revalidation
//  and a local copy to fall back on.
//

import Foundation

/// Downloads a small hosted file, revalidating a cached copy with its ETag, and falls
/// back to that cached copy when the server can't be reached.
struct CachedDownload {
    /// Name used in log messages, e.g. "Installomator-Tracker data".
    let what: String
    let cacheURL: URL
    let cacheMetaURL: URL
    /// How old a cached copy may be and still be used when the server can't be reached.
    /// Nil means any age.
    let maxCacheAge: TimeInterval?

    /// The file's contents, or nil when neither the server nor a usable cached copy has them.
    func fetch(url: URL) -> Data? {
        let meta = (NSDictionary(contentsOf: cacheMetaURL) as? [String: Any]) ?? [:]
        let cachedData = (meta["url"] as? String == url.absoluteString) ? try? Data(contentsOf: cacheURL) : nil
        let fetchedAt = meta["fetchedAt"] as? Date

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if cachedData != nil, let etag = meta["etag"] as? String {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        var responseData: Data?
        var status = 0
        var failure: String?
        var etag: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { failure = error.localizedDescription; return }
            guard let http = response as? HTTPURLResponse else { failure = "no response"; return }
            status = http.statusCode
            etag = http.value(forHTTPHeaderField: "ETag")
            responseData = data
        }.resume()
        if semaphore.wait(timeout: .now() + 30) == .timedOut { failure = "timed out" }

        if failure == nil && status == 304, let cachedData {
            saveMeta(url: url, etag: etag ?? meta["etag"] as? String)
            return cachedData
        }
        if failure == nil && status == 200, let responseData {
            try? responseData.write(to: cacheURL, options: .atomic)
            saveMeta(url: url, etag: etag)
            return responseData
        }

        let reason = failure ?? "HTTP \(status)"
        if let cachedData, let fetchedAt,
           maxCacheAge.map({ Date().timeIntervalSince(fetchedAt) < $0 }) ?? true {
            Logger.log("⚠️ Could not fetch \(what) (\(reason)) — using cached copy from \(ISO8601DateFormatter().string(from: fetchedAt))")
            return cachedData
        }
        Logger.log("⚠️ Could not fetch \(what) (\(reason)) and no usable cached copy")
        return nil
    }

    /// Forgets the cached copy, e.g. when its contents turned out to be unusable.
    func discardCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: cacheMetaURL)
    }

    private func saveMeta(url: URL, etag: String?) {
        var meta: [String: Any] = ["url": url.absoluteString, "fetchedAt": Date()]
        if let etag { meta["etag"] = etag }
        (meta as NSDictionary).write(to: cacheMetaURL, atomically: true)
    }
}
