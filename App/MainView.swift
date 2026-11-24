import SwiftUI
import UIKit

/// 首页：顶部车辆大图卡 + 三组折叠（账号 / 车况详情 / 高级功能）。
/// 版式对应 Android MainActivity（v3.0 整页折叠交互）。
struct MainView: View {
    @StateObject private var st = AppState()
    @Environment(\.colorScheme) private var colorScheme

    @State private var showLogin = false
    @State private var showAbout = false
    @State private var showRaw = false
    @State private var showFirstRun = Store.get(Store.kFirstRunAck).isEmpty
    @State private var secAccount = false
    @State private var secDetail = false
    @State private var secAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    carCard
                    group(title: accountTitle, subtitle: accountSubtitle, open: $secAccount) {
                        accountBody
                    }
                    group(title: "车况详情", subtitle: st.cache?.string("status") ?? "", open: $secDetail) {
                        detailBody
                    }
                    group(title: "高级功能", subtitle: "小组件标题 · 配色 · 自动刷新", open: $secAdvanced) {
                        AdvancedSettingsView(st: st)
                    }
                    Button("关于 · 隐私说明") { showAbout = true }
                        .font(.footnote)
                        .padding(.top, 4)
                    Text("非官方第三方应用，与北汽极狐官方无关")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("极狐车况")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        st.refresh()
                    } label: {
                        if st.loading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView(st: st)
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .sheet(isPresented: $showRaw) {
                RawStateView()
            }
            .alert("使用须知", isPresented: $showFirstRun, actions: {
                Button("我已阅读并同意") {
                    Store.set(Store.kFirstRunAck, "1")
                }
            }, message: {
                Text(firstRunText)
            })
            .onAppear {
                st.refresh()
            }
        }
    }

    // ----------------------------------------------------------- 车辆大图卡

    private var carCard: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.title3.bold())
                    Text(subText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let c = st.cache, c.bool("charging", false) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
            }
            if let img = carImage {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            HStack(spacing: 18) {
                bigStat(value: socText, label: "电量", color: socColor)
                bigStat(value: rangeText, label: "续航", color: .primary)
                bigStat(value: odoText, label: "里程", color: .primary)
            }
            if let loc = st.cache?.string("loc"), !loc.isEmpty {
                Text(loc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !st.lastError.isEmpty {
                Text(st.lastError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var titleText: String {
        if let c = st.cache {
            let t = c.string("title")
            if !t.isEmpty { return t }
        }
        return "我的极狐"
    }

    private var subText: String {
        if !Session.shared.loggedIn {
            return st.needLogin ? "还没登录，点上方账号开始" : "刷新中…"
        }
        if !st.lastError.isEmpty { return st.lastError }
        if let c = st.cache {
            let dataTs = c.string("dataTs")
            let ts = c.string("ts")
            return dataTs.isEmpty ? "更新于 " + ts : "数据 " + dataTs + " · " + ts
        }
        return "—"
    }

    private var carImage: Image? {
        let group = CarModel.resolve(Session.shared.modelCode, Session.shared.vin, Session.shared.model)
        if let ui = CarImages.load(CarModel.defaultCarImage(group)) {
            return Image(uiImage: ui)
        }
        return nil
    }

    private func bigStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var socText: String { st.cache?.string("soc") ?? "--%" }
    private var rangeText: String { st.cache?.string("range") ?? "--km" }
    private var odoText: String { st.cache?.string("odo") ?? "--" }

    private var socColor: Color {
        guard let c = st.cache else { return .primary }
        let s = c.string("soc").replacingOccurrences(of: "%", with: "")
        if let v = Int(s) {
            if v < 15 { return .red }
            if v < 40 { return .orange }
        }
        return .primary
    }

    // ----------------------------------------------------------- 折叠组

    private var accountTitle: String {
        if !Session.shared.loggedIn { return "极狐账号 · 未登录" }
        if !Session.shared.ready { return "极狐账号 · 待授权" }
        return "极狐账号 · 已完成"
    }

    private var accountSubtitle: String {
        if Session.shared.loggedIn {
            return "登录于 " + Session.shared.loginTimeText
        }
        return "手机号 + 短信验证码"
    }

    @ViewBuilder
    private var accountBody: some View {
        if Session.shared.loggedIn {
            row("账号", Session.shared.phone.isEmpty ? "--" : Session.shared.phone)
            row("车型", Session.shared.model.isEmpty ? CarModel.label(CarModel.resolve(Session.shared.modelCode, Session.shared.vin, Session.shared.model)) : Session.shared.model)
            row("车架号", Session.shared.vin.isEmpty ? "--" : Session.shared.vin)
            if !Session.shared.color.isEmpty { row("车漆", Session.shared.color) }
            HStack(spacing: 10) {
                button("重新授权") { showLogin = true }
                button("退出登录") {
                    Session.shared.clearAll()
                    Store.remove(Store.kCache)
                    st.cache = nil
                    st.refresh()
                }
            }
        } else {
            button("登录极狐账号") { showLogin = true }
        }
        Picker("自动刷新", selection: Binding(
            get: { st.autoMin },
            set: { st.autoMin = $0 })) {
            Text("关").tag(0)
            Text("5 分钟").tag(5)
            Text("15 分钟").tag(15)
            Text("30 分钟").tag(30)
            Text("60 分钟").tag(60)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var detailBody: some View {
        if let c = st.cache {
            row("电量", c.string("soc"))
            row("续航", c.string("range"))
            row("总里程", c.string("odo"))
            row("车内温度", c.string("temp"))
            row("车外温度", c.string("out"))
            row("门锁", c.bool("locked", false) ? "已锁车" : (c.bool("lockKnown", false) ? "未锁车" : "门锁未知"))
            if c.bool("sentryKnown", false) { row("哨兵", c.bool("sentry", false) ? "哨兵开" : "哨兵关") }
            if c.int("ac", -1) >= 0 { row("空调", c.int("ac", -1) == 1 ? "空调开" : "空调关") }
            if c.int("win", -1) >= 0 { row("车窗", c.int("win", -1) == 1 ? "车窗开" : "车窗关") }
            row("胎压", c.string("tyre"))
            row("位置", c.string("loc"))
            Button("查看原始车况数据") { showRaw = true }
                .font(.footnote)
        } else {
            Text(st.lastError.isEmpty ? "还没有车况数据，先登录并授权" : st.lastError)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // ----------------------------------------------------------- 组件

    private func group<Content: View>(title: String, subtitle: String, open: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.wrappedValue.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundColor(.primary)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: open.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(14)
            }
            if open.wrappedValue {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline)
            Spacer()
            Text(v.isEmpty ? "--" : v).font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
        }
    }

    private func button(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var firstRunText: String {
        """
        这是一个非官方第三方应用，与北汽极狐官方无关。

        · 你的极狐账号凭据只保存在本机，不经过任何第三方服务器
        · 官方接口随时可能失效
        · 远程控车（空调 / 门锁 / 车窗 / 寻车）有真实后果，请谨慎操作
        """
    }
}
