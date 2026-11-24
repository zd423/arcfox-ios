import SwiftUI
import PhotosUI
import UIKit

/// 高级功能面板（对应 Android 首页「高级功能」五组：远程控制 / 小组件标题 / 高德 Key / 小组件样式 / 字体与图标 + 车图）
struct AdvancedSettingsView: View {
    @ObservedObject var st: AppState

    @State private var widgetTitle = Store.get(Store.kWidgetTitle)
    @State private var amapKey = Store.get(Store.kAmapUser)
    @State private var photoItem: PhotosPickerItem?
    @State private var ctrlMsg = ""
    @State private var cloudOn = CloudSync.enabled
    @State private var cloudTopic = Store.get(Store.kCloudTopic)
    @State private var cloudInfo = CloudSync.lastUploadText

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 共享存储诊断 + 手动重载小组件
            sub("小组件数据链路")
            HStack {
                Text("共享存储：")
                Text(Store.probeGroup() ? "正常（\(Store.channelName)）" : "不可用（已由云同步自动接管）")
                    .fontWeight(.semibold)
                    .foregroundColor(Store.probeGroup() ? .green : .orange)
                Spacer()
                Button("重载小组件") { WidgetBridge.reloadWidgets() }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
            Text("证书组权限：\(Store.certGroupsText)｜实际用的组：\(Store.appGroupId)｜通道：\(Store.channelName)")
                .font(.caption2).foregroundColor(.secondary)

            // 云同步：无 App Group 权限时小组件走云端拉数据（设备自动通道免手填，同步码为备选）
            sub("小组件云同步（无共享权限时的通道）")
            Toggle("开启云同步", isOn: $cloudOn)
                .font(.callout)
                .onChange(of: cloudOn) { on in
                    CloudSync.enabled = on
                    if on && Store.get(Store.kCloudTopic).isEmpty {
                        cloudTopic = CloudSync.autoCode
                        Store.set(Store.kCloudTopic, cloudTopic)
                    }
                }
            if cloudOn {
                Text("自动通道：\(CloudSync.autoCode)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                HStack {
                    Text("同步码：")
                    Text(cloudTopic.isEmpty ? "（未生成）" : cloudTopic)
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.semibold)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Button("复制") {
                        UIPasteboard.general.string = cloudTopic
                        cloudInfo = "已复制，去小组件：长按→编辑→粘贴同步码"
                    }.buttonStyle(.bordered)
                    Button("换一个") {
                        cloudTopic = CloudSync.newTopic()
                        cloudInfo = "已更换同步码，小组件里要重新填一遍"
                    }.buttonStyle(.bordered)
                }
                .font(.callout)
                Button("立即上传") {
                    if let err = CloudSync.upload() {
                        cloudInfo = "上传失败：\(err)"
                    } else {
                        cloudInfo = "上传成功 · " + CloudSync.lastUploadText
                    }
                }
                .buttonStyle(.bordered)
                Text(cloudInfo).font(.caption2).foregroundColor(.secondary)
                Text("开启后每次刷新自动上传；证书重签导致 App Group 失效时，小组件会自动走设备自动通道取数，无需手填同步码。载荷加密，云端只存密文。手动同步码仍可用来把数据带到另一台设备。")
                    .font(.caption2).foregroundColor(.secondary)
            }

            // 远程控制
            sub("远程控制")
            HStack(spacing: 8) {
                ctrlBtn("锁车 / 解锁", "lock.fill") {
                    let locked = TspControl.heldLock() >= 0 ? TspControl.heldLock() == 1 : (TspControl.readCache()?.bool("locked", false) ?? false)
                    return TspControl.setDoor(!locked)
                }
                ctrlBtn("空调", "fanblades") { TspControl.toggle() }
                ctrlBtn("车窗", "rectangle.split.3x1") { TspControl.toggleWindow() }
                ctrlBtn("寻车", "iphone.radiowaves.left.and.right") { TspControl.find() }
            }
            if !ctrlMsg.isEmpty {
                Text(ctrlMsg).font(.caption).foregroundColor(.secondary)
            }

            // 小组件标题
            sub("小组件标题（留空显示车型）")
            HStack {
                TextField("标题", text: $widgetTitle)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Store.set(Store.kWidgetTitle, widgetTitle.trimmingCharacters(in: .whitespaces))
                    WidgetBridge.reloadWidgets()
                }
            }

            // 高德 Key
            sub("高德地图 Key（选填，留空用内置）")
            HStack {
                TextField("Web 服务 Key", text: $amapKey)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Store.set(Store.kAmapUser, amapKey.trimmingCharacters(in: .whitespaces))
                    Store.remove(Store.kGeoCache)
                    st.refresh()
                }
            }
            Text("申请：lbs.amap.com → 控制台 → 创建应用 → 添加 Key，服务平台必须选「Web 服务」")
                .font(.caption2).foregroundColor(.secondary)

            // 小组件样式
            sub("小组件样式")
            Picker("配色", selection: Binding(get: { Theme.raw }, set: { Store.set(Store.kWidgetTheme, $0); WidgetBridge.reloadWidgets() })) {
                Text("浅色").tag("light")
                Text("深色").tag("dark")
                Text("跟随系统").tag("auto")
            }
            .pickerStyle(.segmented)
            HStack {
                Text("圆角 \(Store.getInt(Store.kWidgetRadius, 22))")
                Slider(value: Binding(
                    get: { Double(Store.getInt(Store.kWidgetRadius, 22)) },
                    set: { Store.setInt(Store.kWidgetRadius, Int($0 / 2) * 2); WidgetBridge.reloadWidgets() }), in: 0...30, step: 2)
            }
            HStack {
                Text("不透明度 \(Store.getInt(Store.kWidgetAlpha, 100))%")
                Slider(value: Binding(
                    get: { Double(Store.getInt(Store.kWidgetAlpha, 100)) },
                    set: { Store.setInt(Store.kWidgetAlpha, Int($0 / 10) * 10); WidgetBridge.reloadWidgets() }), in: 20...100, step: 10)
            }
            HStack {
                Text("字号 \(Store.getInt(Store.kWidgetFontPct, 100))%")
                Slider(value: Binding(
                    get: { Double(Store.getInt(Store.kWidgetFontPct, 100)) },
                    set: { Store.setInt(Store.kWidgetFontPct, Int($0)); WidgetBridge.reloadWidgets() }), in: 70...150, step: 5)
            }

            // 车辆图片
            sub("车辆图片（自动识别车型，可自定义覆盖）")
            Text("当前车型：" + CarModel.label(CarModel.resolve(Session.shared.modelCode, Session.shared.vin, Session.shared.model))
                 + (Session.shared.color.isEmpty ? "" : " · " + Session.shared.color)
                 + (CarImages.hasCustom() ? " · 已自定义" : ""))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text("从相册选择")
                        .font(.subheadline)
                }
                if CarImages.hasCustom() {
                    Button("恢复默认") { CarImages.clearCustom() }
                        .font(.subheadline)
                }
            }
            .onChange(of: photoItem) { item in
                guard let item = item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        CarImages.saveCustom(img)
                    }
                }
            }

            // 车控日志
            sub("车控日志")
            let logText = Store.get(Store.kCtrlLog)
            if logText.isEmpty {
                Text("暂无").font(.caption).foregroundColor(.secondary)
            } else {
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sub(_ t: String) -> some View {
        Text(t).font(.subheadline.bold()).padding(.top, 2)
    }

    private func ctrlBtn(_ title: String, _ icon: String, op: @escaping () -> TspControl.Res) -> some View {
        Button {
            ctrlMsg = "正在执行" + title + "…"
            DispatchQueue.global(qos: .userInitiated).async {
                let r = op()
                DispatchQueue.main.async {
                    ctrlMsg = r.msg
                    st.refresh()
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
