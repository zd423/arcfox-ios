import SwiftUI
import UIKit

/// 登录 + 车况授权（对应 LoginActivity.java 两阶段流程）。
struct LoginView: View {
    @ObservedObject var st: AppState
    @Environment(\.dismiss) private var dismiss

    // 阶段：account=手机号验证码登录，auth=车况授权（再收一条短信）
    @State private var stage = 0
    @State private var phone = Session.shared.phone
    @State private var sms = ""
    @State private var busy = false
    @State private var log = ""
    @State private var msg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(stage == 0 ? "登录极狐账号" : "车况授权（会再收一条短信）") {
                    if stage == 0 {
                        TextField("手机号", text: $phone)
                            .keyboardType(.phonePad)
                        SecureField("短信验证码", text: $sms)
                            .keyboardType(.numberPad)
                        HStack {
                            Button("发送验证码") { run { Session.shared.sendSms(phone) } }
                                .disabled(busy || phone.count < 11)
                            Spacer()
                        }
                    } else {
                        TextField("车况授权验证码", text: $sms)
                            .keyboardType(.numberPad)
                        Button("重新发送授权短信") { run { Session.shared.sendAuthSmsAuto(&log) } }
                            .disabled(busy)
                    }
                    Button(stage == 0 ? "登录" : "完成授权") {
                        if stage == 0 {
                            run {
                                let r = Session.shared.login(phone, sms)
                                if r.bizOk {
                                    Session.shared.loadAccount()
                                    Session.shared.loadVehicle()
                                }
                                return r
                            } done: { r in
                                if r.bizOk {
                                    stage = 1
                                    msg = "登录成功，现在做车况授权（会收到第二条短信）"
                                    run { Session.shared.sendAuthSmsAuto(&log) }
                                }
                            }
                        } else {
                            run {
                                let r = Session.shared.authCode(sms)
                                return r
                            } done: { r in
                                if r.bizOk {
                                    msg = "授权成功"
                                    st.refresh()
                                    dismiss()
                                }
                            }
                        }
                    }
                    .disabled(busy || sms.isEmpty)
                }
                if !msg.isEmpty {
                    Section {
                        Text(msg).font(.footnote).foregroundColor(.blue)
                    }
                }
                if !log.isEmpty {
                    Section("过程日志") {
                        Text(log).font(.system(size: 11, design: .monospaced))
                    }
                }
                Section {
                    Text("说明：登录走极狐官方账号接口；车况授权需要再收一条短信，授权后才能拉取车况与远程控车。凭据只保存在本机。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(stage == 0 ? "登录" : "车况授权")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func run(_ op: @escaping () -> ArcApi.Resp, done: ((ArcApi.Resp) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        msg = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = op()
            DispatchQueue.main.async {
                busy = false
                if let e = r.error {
                    msg = e
                } else if !r.bizOk {
                    msg = r.describe
                }
                if r.json != nil {
                    log += "HTTP \(r.http) \(Session.brief(r))\n"
                }
                done?(r)
            }
        }
    }
}

/// 关于 · 隐私说明（对应 AboutActivity.java 六节静态文案）
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("这是什么") {
                    Text("「极狐车况小组件」是一个非官方第三方应用：用你自己的极狐账号，把车况放到主屏幕小组件上，并支持远程控车。与北汽极狐官方无关。")
                }
                Section("你的数据去哪了") {
                    Text("账号凭据（token）与车况缓存只保存在你手机本机的 App Group 存储里，不会经过任何第三方服务器。所有请求都直接发往极狐官方接口。")
                }
                Section("需要的权限") {
                    Text("· 网络：访问极狐官方接口\n· 后台刷新：定时拉车况\n· 通知（可选）：刷新失败提醒")
                }
                Section("怎么删掉数据") {
                    Text("退出登录会清空账号凭据；卸载 App 会删除全部本机数据。")
                }
                Section("风险与免责") {
                    Text("官方接口随时可能变更或失效。远程控车有真实后果：开关空调、门锁、车窗、寻车都会实际作用于车辆，请谨慎操作。使用本应用的一切风险由使用者自行承担。")
                }
                Section("版本") {
                    HStack {
                        Text("极狐车况小组件")
                        Spacer()
                        Text("v3.0 (iOS 移植版)").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("关于")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }
}

/// 车况原始数据诊断页（对应 RawCarStateActivity.java）
struct RawStateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var out = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(out.isEmpty ? "点右上角「探测」连打两次车况接口：\n① queryKeys=status（status 整棵子树）\n② 不带 queryKeys（网关按默认回包）\n\n对比两次结果就能确认档位等信号在哪个 S 码里。" : out)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .navigationTitle("原始车况数据")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(busy ? "探测中…" : "探测") { probe() }
                        .disabled(busy)
                }
            }
        }
    }

    private func probe() {
        guard !busy else { return }
        let s = Session.shared
        guard !s.vin.isEmpty else {
            out = "还没拿到 VIN，先登录并刷新一次车况"
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var lines = ""
            for (tag, keys) in [("① status 子树", "status"), ("② 全量默认", "")] {
                let resp = ArcApi.carGet(ArcApi.carStateProbePath(s.vin, keys), s.tspToken)
                lines += "==== \(tag) ====\nHTTP \(resp.http)\n"
                if let j = resp.json {
                    if let d = j.dict("data") {
                        lines += "data 顶层键: " + d.obj.keys.joined(separator: ", ") + "\n"
                        if let stt = d.dict("status") {
                            for k in stt.obj.keys.sorted() {
                                lines += "  S码 \(k) = \(stt.string(k))\n"
                            }
                        }
                    }
                    lines += "\n---- 原文（前 9KB）----\n" + String(resp.body.prefix(9216)) + "\n\n"
                } else {
                    lines += resp.describe + "\n\n"
                }
            }
            DispatchQueue.main.async {
                out = lines
                busy = false
            }
        }
    }
}
