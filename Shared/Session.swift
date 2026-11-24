import Foundation

/// App Group 共享存储：主 App 与小组件扩展共用一份键值存储（对应 Android 的 SharedPreferences）。
/// 共享存储：优先用固定路径共享文件（TrollStore + no-sandbox 私有权能下 App 与
/// 小组件扩展直接读写同一文件，不依赖 App Group 容器）；文件通道不可用时自动
/// 回退 UserDefaults suite（对应 Android 的 SharedPreferences，API 保持一致）。
enum Store {
    static let name = "arcfox_widget_cfg"
    static let sharedPath = "/var/mobile/Library/Preferences/arcfox_widget_shared.plist"

    /// App Group ID 不写死：从签名时嵌入的 embedded.mobileprovision 里解析证书
    /// 实际授权的 App Group（全能签/自签换证书、换组名都自动适配）。
    static let appGroupId: String = resolveGroupId()

    static var d: UserDefaults { UserDefaults(suiteName: appGroupId) ?? .standard }

    /// 读 embedded.mobileprovision 的 Entitlements（签名时嵌进包里的证书授权）。
    private static func provisionEntitlements() -> [String: Any]? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        // CMS 容器里夹着一段明文 XML plist，直接切出来
        let body = String(data: raw, encoding: .isoLatin1) ?? String(data: raw, encoding: .utf8) ?? ""
        guard let start = body.range(of: "<?xml"), let end = body.range(of: "</plist>") else { return nil }
        let xml = String(body[start.lowerBound..<end.upperBound])
        guard let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }

    private static func resolveGroupId() -> String {
        let fallback = "group.com.arcfoxplus.widget"
        guard let ent = provisionEntitlements(),
              let groups = ent["com.apple.security.application-groups"] as? [String],
              let g = groups.first, !g.isEmpty else { return fallback }
        return g
    }

    /// 诊断：证书描述文件里实际授权的 App Group 列表（空 = 证书没这权限）。
    static var certGroupsText: String {
        guard let ent = provisionEntitlements() else { return "读不到描述文件(未签名？)" }
        guard let groups = ent["com.apple.security.application-groups"] as? [String], !groups.isEmpty else {
            return "无(证书没有App Group权限)"
        }
        return groups.joined(separator: ", ")
    }

    private static let ioLock = NSLock()
    private static var fileUsable: Bool?

    private static let keyPrefixes = ["acct_", "cache", "last_", "widget_", "geo_", "amap_",
                                      "vehicle_", "ctrl_", "refresh_", "tsp_", "ac_", "lock_",
                                      "win_", "first_run_", "auto_", "__probe", "cloud_"]

    /// 云同步上传时排除的大体积诊断键（小组件用不到）。
    private static let uploadSkip = ["vehicle_raw", "vehicle_ts", "ctrl_log", "refresh_log", "geo_cache"]

    private static func ours(_ k: String) -> Bool { keyPrefixes.contains { k.hasPrefix($0) } }

    private static func writeDictRaw(_ dict: [String: Any]) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return false }
        return FileManager.default.createFile(atPath: sharedPath, contents: data,
            attributes: [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    /// 兜底读：`UserDefaults(suiteName:)` 对未授权的 App Group 会返回一个"空壳"对象，
    /// 写入静默失败、读出为空，所以这里必须同时合并 standard（沙盒内一定可写）。
    private static func seedFromSuite() -> [String: Any] {
        var seed: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where ours(k) { seed[k] = v }
        for (k, v) in d.dictionaryRepresentation() where ours(k) { seed[k] = v }
        return seed
    }

    /// 读全量：文件通道优先；文件不存在时先用 suite 旧数据建文件（自动迁移）。
    private static func loadAll() -> [String: Any] {
        ioLock.lock(); defer { ioLock.unlock() }
        if let dict = NSDictionary(contentsOfFile: sharedPath) as? [String: Any] {
            fileUsable = true
            return dict
        }
        let seed = seedFromSuite()
        if writeDictRaw(seed), FileManager.default.fileExists(atPath: sharedPath) {
            fileUsable = true
            return seed
        }
        fileUsable = false
        return seed   // 回退：suite（各进程独立，仅保底）
    }

    private static func saveValue(_ k: String, _ v: Any?) {
        ioLock.lock(); defer { ioLock.unlock() }
        var dict = (NSDictionary(contentsOfFile: sharedPath) as? [String: Any]) ?? seedFromSuite()
        if let v = v { dict[k] = v } else { dict.removeValue(forKey: k) }
        if writeDictRaw(dict) { return }
        fileUsable = false
        // 回退写 suite + standard：未授权 App Group 的 suite 是空壳，只有 standard 一定落盘
        if let s = v as? String {
            d.set(s, forKey: k)
            UserDefaults.standard.set(s, forKey: k)
        } else if let i = v as? Int {
            d.set(i, forKey: k)
            UserDefaults.standard.set(i, forKey: k)
        } else {
            d.removeObject(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    static func get(_ k: String, _ def: String = "") -> String {
        let s = loadAll()[k] as? String
        return (s == nil || s!.isEmpty) ? def : s!
    }

    static func set(_ k: String, _ v: String) { saveValue(k, v) }

    static func remove(_ k: String) { saveValue(k, nil) }

    static func getInt(_ k: String, _ def: Int) -> Int {
        loadAll()[k] as? Int ?? def
    }

    static func setInt(_ k: String, _ v: Int) { saveValue(k, v) }

    static func getLong(_ k: String, _ def: Int64) -> Int64 {
        if let v = loadAll()[k] as? Int { return Int64(v) }
        return def
    }

    static func setLong(_ k: String, _ v: Int64) { saveValue(k, Int(v)) }

    /// 导出全部自有键（云同步上传用；排除大体积诊断键）。
    static func exportDict() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in loadAll() where ours(k) && !uploadSkip.contains(k) { out[k] = v }
        return out
    }

    /// 云端字典导入本地。小组件进程里 App Group 通常是空壳，
    /// 所以同时写 suite 与 standard，并强制落盘，保证紧随其后的 readCache() 一定能读到。
    static func importDict(_ dict: [String: Any]) {
        for (k, v) in dict where ours(k) {
            d.set(v, forKey: k)
            UserDefaults.standard.set(v, forKey: k)
        }
        d.synchronize()
        UserDefaults.standard.synchronize()
    }

    /// 诊断：跨进程共享是否真实可用——共享文件通道，或证书授权的 App Group 容器。
    @discardableResult
    static func probeGroup() -> Bool {
        let t = "ok\(Int(Date().timeIntervalSince1970))"
        set("__probe", t)
        _ = loadAll()
        if fileUsable == true && get("__probe") == t { return true }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil
    }

    /// 诊断用：当前走的是哪条通道。
    static var channelName: String {
        if fileUsable == true { return "共享文件(TrollStore)" }
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil {
            return "App Group(\(appGroupId))"
        }
        return "各自本地存储(无共享！)"
    }

    // ------------------------------------------------------------- 键名（与 Android 版一致）

    static let kCache = "cache"
    static let kCacheTs = "cache_ts"
    static let kLastError = "last_error"
    static let kAutoMin = "auto_refresh_min"
    static let kWidgetTheme = "widget_theme"
    static let kWidgetTitle = "widget_title"
    static let kWidgetScale = "widget_scale"
    static let kWidgetFontPct = "widget_font_pct"
    static let kWidgetIconDp = "widget_icon_dp"
    static let kWidgetAlpha = "widget_alpha"
    static let kWidgetRadius = "widget_radius"
    static let kLastNight = "widget_night_applied"
    static let kGeoCache = "geo_cache"
    static let kAmapUser = "amap_key_user"
    static let kVehicleTs = "vehicle_ts"
    static let kVehicleRaw = "vehicle_raw"
    static let kCarColorName = "car_color_name"
    static let kCtrlKey = "ctrl_key"
    static let kCtrlLog = "ctrl_log"
    static let kCtrlMsg = "ctrl_msg"
    static let kRefreshLog = "refresh_log"
    static let kTspSeq = "tsp_seq"
    static let kAcTemp = "ac_temp"
    static let kAcHold = "ac_hold"
    static let kLockHold = "lock_hold"
    static let kWinHold = "win_hold"
    static let kFirstRunAck = "first_run_ack"
    static let kCloudTopic = "cloud_topic"
    static let kCloudOn = "cloud_sync_on"
    static let kCloudTs = "cloud_sync_ts"

    static func ctrlKey() -> String {
        let s = get(kCtrlKey)
        if s.count >= 8 { return s }
        var out = ""
        while out.count < 16 {
            out += String(format: "%x", Int.random(in: 0..<16))
        }
        set(kCtrlKey, out)
        return out
    }
}

/// 登录态（对应 Android Session.java）
final class Session {
    static let shared = Session()

    private let kAuthUid = "acct_auth_uid"
    private let kColor = "acct_vehicle_color"
    private let kDevice = "acct_device_id"
    private let kLoginTs = "acct_login_ts"
    private let kMain = "acct_main_token"
    private let kModel = "acct_vehicle_model"
    private let kModelCode = "acct_vehicle_model_code"
    private let kPhone = "acct_phone"
    private let kPlate = "acct_vehicle_plate"
    private let kRC = "acct_rc_token"
    private let kRefresh = "acct_refresh_token"
    private let kSdsTsp = "acct_sds_tsp_id"
    private let kSubModelCode = "acct_vehicle_sub_model_code"
    private let kTspToken = "acct_tsp_token"
    private let kTspUid = "acct_tsp_uid"
    private let kVin = "acct_vin"
    private let lock = NSLock()

    func read(_ k: String) -> String { Store.get(k) }

    var phone: String { read(kPhone) }
    var vin: String { read(kVin) }
    var model: String { read(kModel) }
    var modelCode: String { read(kModelCode) }
    var color: String { read(kColor) }
    var plate: String { read(kPlate) }
    var tspUid: String { read(kTspUid) }
    var sdsTspId: String { read(kSdsTsp) }
    var authUid: String { read(kAuthUid) }
    var mainToken: String { read(kMain) }
    var tspToken: String { read(kTspToken) }
    var refreshToken: String { read(kRefresh) }
    var rcToken: String { read(kRC) }

    var authUidCandidates: [String] {
        var set: [String] = []
        for c in [authUid, sdsTspId, tspUid] where !c.isEmpty && !set.contains(c) {
            set.append(c)
        }
        return set
    }

    var bestAuthUid: String { authUidCandidates.first ?? "" }

    var ready: Bool { !tspToken.isEmpty && !vin.isEmpty }
    var loggedIn: Bool { !mainToken.isEmpty }

    var deviceId: String {
        let s = read(kDevice)
        if !s.isEmpty { return s }
        let n = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        Store.set(kDevice, n)
        return n
    }

    var loginTs: Int64 { Store.getLong(kLoginTs, 0) }

    var loginTimeText: String {
        guard loginTs > 0 else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(loginTs) / 1000))
    }

    func saveRc(_ s: String) {
        guard !s.isEmpty else { return }
        Store.set(kRC, s)
    }

    func clearAll() {
        for k in [kMain, kTspUid, kSdsTsp, kVin, kTspToken, kRefresh, kLoginTs, kModel, kPlate] {
            Store.remove(k)
        }
    }

    // ------------------------------------------------------------- 登录 / 授权

    @discardableResult
    func sendSms(_ phone: String) -> ArcApi.Resp {
        Store.set(kPhone, phone)
        let body = JSON(["verifyCodeUseFlag": "LOGIN", "ruleFlag": "darkRule", "mobile": phone])
        return ArcApi.accountPost("user/public/verifyCode/getVerifyCodeNew", deviceId, body, nil)
    }

    @discardableResult
    func login(_ phone: String, _ code: String) -> ArcApi.Resp {
        Store.set(kPhone, phone)
        let body = JSON([
            "cityCode": "110000",
            "cityName": "北京市",
            "deviceId": deviceId,
            "deviceModel": ArcApi.deviceModel(),
            "deviceBrand": "Apple",
            "mobile": phone,
            "verifyCode": code,
            "ruleFlag": "darkRule",
            "provinceCode": "110000",
            "provinceName": "北京市",
        ])
        let resp = ArcApi.accountPost("user/public/login/loginByMobile", deviceId, body, nil)
        if resp.bizOk, let data = resp.json?.dict("data") {
            let d = data
            let token = d.string("token")
            if !token.isEmpty { Store.set(kMain, token) }
            let tspUid = d.string("tspUid")
            if !tspUid.isEmpty { Store.set(kTspUid, tspUid) }
            let sds = d.string("sdsTspId")
            if !sds.isEmpty { Store.set(kSdsTsp, sds) }
            let t = Session.firstNonEmpty(d.string("tspAccessToken"), d.string("accessToken"))
            if !t.isEmpty { Store.set(kTspToken, t) }
            Store.setLong(kLoginTs, Int64(Date().timeIntervalSince1970 * 1000))
        }
        return resp
    }

    @discardableResult
    func loadAccount() -> ArcApi.Resp {
        let resp = ArcApi.accountGet("tdata-sync/public/account/getTspAccountInfo", deviceId, mainToken)
        if resp.bizOk, let data = resp.json?.dict("data") {
            let tspUid = data.string("tspUid")
            if !tspUid.isEmpty { Store.set(kTspUid, tspUid) }
            let sds = data.string("sdsTspId")
            if !sds.isEmpty { Store.set(kSdsTsp, sds) }
        }
        return resp
    }

    @discardableResult
    func loadVehicle() -> ArcApi.Resp {
        let resp = ArcApi.accountGet("vehicle-customer/public/vehicle/getDefaultVehicle", deviceId, mainToken)
        if resp.bizOk, let data = resp.json?.dict("data") {
            var v = data.string("vin")
            if v.isEmpty { v = data.string("vehicleVin") }
            if !v.isEmpty { Store.set(kVin, v.uppercased()) }

            // seriesName 是「车系」不是「车型」：最具体的放前面，车系名放最后兜底
            let model = Session.firstNonEmpty(data.string("vehicleModelName"), data.string("modelName"),
                                      data.string("vehicleModel"), data.string("seriesName"))
            if !model.isEmpty { Store.set(kModel, model) }

            let code = Session.firstNonEmpty(data.string("vehicleModelCode"), data.string("vehicleSeriesCode"),
                                     data.string("modelCode"), data.string("seriesCode"),
                                     data.string("subVehicleModelCode"), data.string("vehicleType"))
            if !code.isEmpty { Store.set(kModelCode, code) }

            let sub = data.string("subVehicleModelCode")
            if !sub.isEmpty { Store.set(kSubModelCode, sub) }

            let plate = Session.firstNonEmpty(data.string("plateNo"), data.string("plateNumber"))
            if !plate.isEmpty { Store.set(kPlate, plate) }

            let color = Session.pickColor(data)
            if !color.isEmpty {
                Store.set(kColor, color)
                Store.set(Store.kCarColorName, color)
            }
            let raw = resp.body
            if !raw.isEmpty {
                Store.set(Store.kVehicleRaw, String(raw.prefix(20000)))
            }
        }
        return resp
    }

    // ------------------------------------------------------------- 车况授权链路

    func sendAuthSmsWith(_ userId: String) -> ArcApi.Resp {
        let body = JSON(["vin": vin, "userId": userId])
        let resp = ArcApi.carPost("auth/signinsms", body, nil)
        if resp.bizOk { Store.set(kAuthUid, userId) }
        return resp
    }

    func sendAuthSmsAuto(_ log: inout String) -> ArcApi.Resp {
        let cands = authUidCandidates
        if cands.isEmpty {
            var r = ArcApi.Resp()
            r.error = "没有可用的 userId（tspUid / sdsTspId 都是空的）"
            return r
        }
        var last: ArcApi.Resp?
        for uid in cands {
            let resp = sendAuthSmsWith(uid)
            log += "userId=\(Session.mask(uid)) → HTTP \(resp.http) \(Session.brief(resp))\n"
            if resp.bizOk { return resp }
            last = resp
        }
        return last ?? ArcApi.Resp()
    }

    @discardableResult
    func authCode(_ sms: String) -> ArcApi.Resp {
        let uid = authUid.isEmpty ? bestAuthUid : authUid
        return authCode(sms, uid)
    }

    @discardableResult
    func authCode(_ sms: String, _ userId: String) -> ArcApi.Resp {
        var uid = userId
        if uid.isEmpty { uid = bestAuthUid }
        let body = JSON(["vin": vin, "userId": uid, "smsCode": sms])
        let resp = ArcApi.carPost("auth/signin", body, nil)
        if resp.bizOk, let data = resp.json?.dict("data") {
            let t = data.string("token")
            if !t.isEmpty { Store.set(kTspToken, t) }
            let rt = data.string("refreshToken")
            if !rt.isEmpty { Store.set(kRefresh, rt) }
            Session.captureRc(data)
            Store.setLong(kLoginTs, Int64(Date().timeIntervalSince1970 * 1000))
        }
        return resp
    }

    @discardableResult
    func refresh() -> ArcApi.Resp {
        lock.lock()
        defer { lock.unlock() }
        if !refreshToken.isEmpty && !vin.isEmpty {
            let body = JSON(["vin": vin, "refreshToken": refreshToken])
            let resp = ArcApi.carPost("auth/refreshtoken", body, nil)
            if resp.bizOk, let data = resp.json?.dict("data") {
                let t = data.string("token")
                if !t.isEmpty { Store.set(kTspToken, t) }
                let rt = data.string("refreshToken")
                if !rt.isEmpty { Store.set(kRefresh, rt) }
                Session.captureRc(data)
            }
            return resp
        }
        var r = ArcApi.Resp()
        r.error = "缺少 refreshToken，需要重新走一次车况授权"
        return r
    }

    func ensureToken() -> Bool {
        if !tspToken.isEmpty { return true }
        if refreshToken.isEmpty { return false }
        return refresh().bizOk && !tspToken.isEmpty
    }

    // ------------------------------------------------------------- helpers

    static func firstNonEmpty(_ vals: String...) -> String {
        for v in vals where !v.isEmpty && v != "null" { return v }
        return ""
    }

    static func captureRc(_ data: JSON) {
        for (k, v) in data.obj {
            let lk = k.lowercased()
            if lk.contains("token") && !lk.contains("refresh") && (lk.contains("rc") || lk.contains("control") || lk.contains("rctrl")) {
                if let s = v as? String, !s.isEmpty, s != "null" {
                    Store.set("acct_rc_token", s)
                }
            }
        }
    }

    static func mask(_ s: String) -> String {
        if s.isEmpty { return "(空)" }
        if s.count <= 6 { return String(s.prefix(1)) + "***" }
        return String(s.prefix(4)) + "***" + String(s.suffix(2))
    }

    static func brief(_ r: ArcApi.Resp?) -> String {
        guard let r = r else { return "(无)" }
        if let e = r.error { return e }
        if let j = r.json {
            var m = j.string("message")
            if m.isEmpty { m = j.string("errorMessage") }
            var code = ""
            if let c = j.opt("code") { code = "code=\(c.value)" }
            return (code + " " + m).trimmingCharacters(in: .whitespaces)
        }
        return ArcApi.head(r.body, 120)
    }

    // 车漆颜色识别：平铺字段优先，递归扫兜底（对应 Session.pickColor / scanColor）
    static func pickColor(_ o: JSON) -> String {
        let flat = pickColorFlat(o)
        if !flat.isEmpty { return flat }
        var name = ""
        var code = ""
        scanColor(o.obj, &name, &code, 0)
        return joinColor(name, code)
    }

    private static func pickColorFlat(_ o: JSON) -> String {
        for k in ["color", "vehicleColor", "exteriorColor", "bodyColor", "paint", "paintColor"] {
            if let sub = o.dict(k) {
                let v = joinColor(
                    Session.firstNonEmpty(sub.string("colorName"), sub.string("name"), sub.string("value")),
                    Session.firstNonEmpty(sub.string("colorCode"), sub.string("code"), sub.string("colorNo")))
                if !v.isEmpty { return v }
            }
        }
        return joinColor(
            Session.firstNonEmpty(o.string("colorName"), o.string("vehicleColorName"), o.string("exteriorColorName"),
                          o.string("bodyColorName"), o.string("paintColorName"), o.string("vehicleColor"),
                          o.string("bodyColor"), o.string("exteriorColor"), o.string("paintColor"), o.string("color")),
            Session.firstNonEmpty(o.string("colorCode"), o.string("vehicleColorCode"), o.string("colorNo"),
                          o.string("paintCode"), o.string("exteriorColorCode")))
    }

    private static func scanColor(_ node: Any, _ name: inout String, _ code: inout String, _ depth: Int) {
        guard depth <= 4 else { return }
        if let o = node as? [String: Any] {
            for (key, val) in o {
                let k = key.lowercased()
                if let sub = val as? [String: Any] {
                    scanColor(sub, &name, &code, depth + 1)
                } else if let arr = val as? [[String: Any]] {
                    for sub in arr.prefix(5) {
                        scanColor(sub, &name, &code, depth + 1)
                    }
                } else if let s = val as? String {
                    let v = cleanColor(s)
                    if v.isEmpty || v.count > 24 { continue }
                    if !k.contains("color") && !k.contains("paint") { continue }
                    let isCode = k.contains("code") || k.contains("no")
                    if isCode {
                        if code.isEmpty, v.range(of: "^[A-Za-z]{2,4}$", options: .regularExpression) != nil {
                            code = v
                        }
                    } else if name.isEmpty, v.range(of: "^[0-9]+$", options: .regularExpression) == nil {
                        name = v
                    }
                }
            }
        }
    }

    private static func joinColor(_ n: String, _ c: String) -> String {
        var a = cleanColor(n)
        var b = cleanColor(c)
        if a.lowercased() == b.lowercased() { b = "" }
        if a.isEmpty { a = b; b = "" }
        if a.isEmpty { return "" }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private static func cleanColor(_ s: String) -> String {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.isEmpty || v.hasPrefix("{") || v.hasPrefix("[") { return "" }
        return v
    }
}
