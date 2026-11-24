import Foundation
import CryptoKit

/// 极狐官方接口访问层：签名、请求，全部照 Android 版 Api.java 移植。
enum ArcApi {

    static let appCode = "750"
    static let appKey = "9821426645"
    static let appVersion = "3.4.32"
    static let secret = "9b3e08953e1a2c5192591d368e67513f"
    static let hostAccount = "https://mg.arcfox.cn/"
    static let hostCar = "https://sdkserver-n5.bjev.com.cn/api/"
    static let pathCarState = "rc/bctp/carState/query/"
    static let pathVehicleCondition = "tdata-sync/public/tsp/getVehicleCondition"
    static let ua = "BMSuperApp/3.4.32 (com.bxbe.arcfox; build:750; Android 15) OkHttp/4.12.0"
    static let queryKeys = "gps,kmTotal,limitedDriving,current,chargingleft,soc,insideTemperature,chrgDchaPwrDisp,chrgDmPwr,vehSpd,status.S3,status.S4,status.S49,status.S50,status.S51,status.S52,status.S67,status.S112,status.S116,status.S128,status.S105,status.statusDataSendTime"

    struct Resp {
        var body = ""
        var error: String?
        var http = 0
        var json: JSON?

        var ok: Bool { error == nil && (200..<300).contains(http) && json != nil }

        var bizOk: Bool {
            guard let j = json else { return false }
            let codeOk: Bool
            if let c = j.optValue("code") {
                let s = String(describing: c.value)
                codeOk = s == "0" || s == "200"
            } else {
                codeOk = true
            }
            let st = j.string("status").uppercased()
            let statusOk = st.isEmpty || st == "SUCCEED" || st == "SUCCESS"
            return codeOk && statusOk && j.bool("success", true)
        }

        var describe: String {
            if let e = error { return e }
            if let j = json {
                var m = j.string("message")
                if m.isEmpty { m = j.string("errorMessage") }
                if !m.isEmpty { return "HTTP \(http) · \(m)" }
            }
            return "HTTP \(http) · \(ArcApi.head(body, 180))"
        }
    }

    // ------------------------------------------------------------- 签名

    static func pct(_ s: String) -> String {
        // 与 Java 端 pct() 完全一致：只留 [a-zA-Z0-9\-._]，其余按 UTF-8 字节 %XX（大写）
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func md5hex(_ s: String) -> String {
        let d = Insecure.MD5.hash(data: Data(s.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    static func sign(_ path: String, _ params: [String: String]) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        var sb = p + "_"
        for k in params.keys.sorted() {
            sb += "\(k)=\(params[k] ?? "")_"
        }
        sb += secret
        return md5hex(pct(sb))
    }

    static func signedParams(_ path: String, _ token: String?, _ extra: [String: String]? = nil) -> [String: String] {
        var m: [String: String] = [:]
        m["appkey"] = appKey
        m["nonce"] = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        m["signt"] = String(Int64(Date().timeIntervalSince1970 * 1000))
        if let t = token, !t.isEmpty { m["token"] = t }
        if let e = extra {
            for (k, v) in e where !v.isEmpty { m[k] = v }
        }
        m["sign"] = sign(path, m)
        return m
    }

    static func query(_ params: [String: String]) -> String {
        params.map { enc($0.key) + "=" + enc($0.value) }.joined(separator: "&")
    }

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func baseHeaders(_ deviceId: String) -> [String: String] {
        [
            "appcode": appCode,
            "appversion": appVersion,
            "platform": "Android",
            "deviceid": deviceId,
            "User-Agent": ua,
            "Accept": "application/json",
        ]
    }

    // ------------------------------------------------------------- 业务请求

    static func accountGet(_ path: String, _ deviceId: String, _ token: String, _ extra: [String: String]? = nil) -> Resp {
        send(hostAccount + path + "?" + query(signedParams(path, token, extra)), "GET", nil, baseHeaders(deviceId))
    }

    static func vehicleCondition(_ vin: String, _ modelCode: String, _ deviceId: String, _ token: String) -> Resp {
        accountGet(pathVehicleCondition, deviceId, token, ["vin": vin.uppercased(), "vehicleModelCode": modelCode])
    }

    static func accountPost(_ path: String, _ deviceId: String, _ body: JSON, _ token: String?) -> Resp {
        var h = baseHeaders(deviceId)
        h["Content-Type"] = "application/json;charset=utf-8"
        h["devicemodel"] = deviceModel()
        h["aid"] = "0"
        h["vin"] = "unknown"
        let url = hostAccount + path + "?" + query(signedParams(path, token))
        return send(url, "POST", body.raw, h)
    }

    static func accountPostRaw(_ path: String, _ deviceId: String, _ body: String, _ token: String) -> Resp {
        var h = baseHeaders(deviceId)
        h["Content-Type"] = "application/json; charset=UTF-8"
        h["devicemodel"] = deviceModel()
        let url = hostAccount + path + "?" + query(signedParams(path, token))
        return send(url, "POST", body, h)
    }

    static func carGet(_ path: String, _ token: String) -> Resp {
        var h = ["User-Agent": ua, "Accept": "application/json"]
        h["Authorization"] = "Bearer " + strip(token)
        return send(hostCar + path, "GET", nil, h)
    }

    static func carPost(_ path: String, _ body: JSON, _ token: String?) -> Resp {
        var h: [String: String] = [
            "Content-Type": "application/json;charset=utf-8",
            "User-Agent": ua,
            "Accept": "application/json",
        ]
        if let t = token, !t.isEmpty { h["Authorization"] = "Bearer " + strip(t) }
        return send(hostCar + path, "POST", body.raw, h)
    }

    static func carStatePath(_ vin: String) -> String {
        pathCarState + vin.uppercased() + "?queryKeys=" + queryKeys + "&_t=" + String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    static func carStateProbePath(_ vin: String, _ keys: String?) -> String {
        var p = pathCarState + vin.uppercased()
        var has = false
        if let k = keys, !k.trimmingCharacters(in: .whitespaces).isEmpty {
            p += "?queryKeys=" + k.trimmingCharacters(in: .whitespaces)
            has = true
        }
        return p + (has ? "&" : "?") + "_t=" + String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        // machine 是 CChar 元组（Int8），必须按字节读取，不能强转 UInt8
        let id = withUnsafeBytes(of: &sys.machine) { buf -> String in
            let bytes = buf.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return id.isEmpty ? "iPhone" : id
    }

    static func strip(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespaces)
        return s.lowercased().hasPrefix("bearer ") ? String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) : s
    }

    // ------------------------------------------------------------- HTTP

    static func send(_ urlStr: String, _ method: String, _ body: String?, _ headers: [String: String],
                     connectTimeout: Double = 12, readTimeout: Double = 18) -> Resp {
        var r = Resp()
        guard let url = URL(string: urlStr) else {
            r.error = "URL 无效"
            return r
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = max(connectTimeout, readTimeout)
        for (k, v) in headers where !v.isEmpty {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let b = body {
            req.httpBody = Data(b.utf8)
        }
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let e = err {
                r.error = String(describing: type(of: e)) + (e.localizedDescription.isEmpty ? "" : ": " + e.localizedDescription)
                return
            }
            let hr = resp as? HTTPURLResponse
            r.http = hr?.statusCode ?? 0
            r.body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            if let b = data, r.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                r.json = JSON(b)
            }
        }.resume()
        _ = sem.wait(timeout: .now() + .seconds(Int(connectTimeout + readTimeout + 2)))
        return r
    }

    static func head(_ s: String?, _ n: Int) -> String {
        guard let s = s else { return "(空)" }
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return flat.count <= n ? flat : String(flat.prefix(n)) + "…"
    }
}

// --------------------------------------------------------------- 轻量 JSON

/// 包一层 JSONObject 的等价物，方便从 Java 端逐行照搬解析逻辑。
final class JSON {
    var obj: [String: Any]

    init(_ data: Data) { obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    convenience init(_ string: String) { self.init(Data(string.utf8)) }
    init(_ dict: [String: Any]) { obj = dict }

    var raw: String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    var rawUnsorted: String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    func opt(_ k: String) -> (value: Any, isNull: Bool)? {
        guard let v = obj[k] else { return nil }
        return (v, v is NSNull)
    }

    func string(_ k: String) -> String {
        switch obj[k] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    func bool(_ k: String, _ def: Bool) -> Bool {
        switch obj[k] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return def
        }
    }

    func int(_ k: String, _ def: Int) -> Int {
        switch obj[k] {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? def
        default: return def
        }
    }

    func double(_ k: String) -> Double? {
        switch obj[k] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    func has(_ k: String) -> Bool { obj[k] != nil }

    func dict(_ k: String) -> JSON? {
        if let d = obj[k] as? [String: Any] { return JSON(d) }
        // 「被塞成字符串的 JSON 对象」还原（对应 Java 端 obj()）
        if let s = obj[k] as? String, s.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            let j = JSON(s)
            return j.obj.isEmpty ? nil : j
        }
        return nil
    }

    func array(_ k: String) -> [[String: Any]]? {
        obj[k] as? [[String: Any]]
    }

    func optValue(_ k: String) -> (value: Any, isNull: Bool)? { opt(k) }

    var keys: [String] { obj.keys.sorted() }
}
