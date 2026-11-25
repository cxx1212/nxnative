// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    let checking: Bool
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("云存档")
                Spacer()
                Text(folder.isEmpty ? "关闭" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "在 iCloud 云盘中选择文件夹…" : "选择其他文件夹…") { picking = true }
                .disabled(checking)
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "已保存。按下开始游戏后，游戏将使用此文件夹。"
                            refresh()
                        } else {
                            note = "无法记住该文件夹，请换一个试试。"
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("关闭云存档", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
                .disabled(checking)
            }
        } footer: {
            Text(note.isEmpty
                 ? "在 iCloud 云盘中选择一个文件夹，并在 Mac 版的云存档中选择同一个。游戏开始时存档会被载入，每次存档后会被传出；被替换的存档会保留在 save-backups 中。"
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "之前选择的文件夹已无法读取，请重新选择。"
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped
    @State private var report: SaveSyncReport?
    @State private var asking: SaveSyncReport.Step?

    var body: some View {
        GeometryReader { geometry in
            // Landscape: the game's name and Play on the left third, the settings beside them; upright (Rotation, an iPad turned), the name and Play above the settings
            if geometry.size.width >= geometry.size.height {
                HStack(spacing: 0) {
                    header(icon: 96)
                        .padding(16)
                        .frame(width: geometry.size.width / 3, height: geometry.size.height)
                    settingsList.frame(width: geometry.size.width * 2 / 3)
                }
            } else {
                VStack(spacing: 0) {
                    header(icon: 64).padding(.horizontal, 16).padding(.vertical, 12)
                    settingsList
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: "iPhone")) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("取消", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: "iPhone")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("使用这台 iPhone 的存档") { go("offline") }   // the mount does not wait for the cloud again
            Button("重试") { DispatchQueue.main.async { start() } }
            Button("取消", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: "iPhone")) }
        .confirmationDialog(SaveSyncReport.missingTitle, isPresented: isAsking(.missing), titleVisibility: .visible, presenting: report) { r in
            Button("重试") { DispatchQueue.main.async { start() } }
            Button("不发送直接开始") { go("offline") }   // this iPhone's save, not sent: the next start compares again
            Button(r.sendLabel(here: "iPhone"), role: .destructive) { go(r.localChoice) }   // local:none
            Button("取消", role: .cancel) {}
        } message: { r in Text(r.missingMessage(here: "iPhone")) }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Rotation turns the screen as soon as it is picked, before Play (front_ios.m dm_rotation_set); the saved pick at once when the screen shows
        .onAppear { if let v = m.values["DM_ROTATION"] { dm_rotation_set(v) } }
        .onChange(of: m.values["DM_ROTATION"]) { _, v in if let v { dm_rotation_set(v) } }
    }

    private func header(icon size: CGFloat) -> some View {
        VStack(spacing: size > 64 ? 16 : 8) {
            if let icon = appIcon() {
                Image(uiImage: icon).resizable().frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 22 / 96))
                    .accessibilityHidden(true)
            }
            Text((info("CFBundleDisplayName") as? String) ?? "游戏")
                .font(.title.weight(.bold)).multilineTextAlignment(.center)
            Text("版本 \((info("CFBundleShortVersionString") as? String) ?? "")")
                .font(.callout).foregroundStyle(.secondary)
            playButton
        }
    }

    private var settingsList: some View {
        List {
            ForEach(m.sections, id: \.self) { section in
                let rows = m.rows(in: section)
                if !rows.isEmpty {
                    Section(section) {
                        ForEach(rows) { SettingRow(s: $0, m: m) }
                    }
                }
            }
            Section {
                Button("恢复测试默认值") { m.reset() }
                    .disabled(!m.changed)
            } footer: {
                Text("恢复为该游戏测试时使用的全部设置。")
            }
            // The background save check reads the selected folder until it returns.
            CloudSavesSection(checking: checking)
            Section {
                HStack {
                    Text("可用内存")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 12, for: .scrollContent)
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: start) { Text("开始游戏").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large).disabled(checking)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
        if checking {
            VStack(spacing: 6) {
                HStack(spacing: 6) { ProgressView(); Text("正在检查云存档…").font(.callout).foregroundStyle(.secondary) }
                Button("没有它也开始") { check += 1; go("offline") }.font(.callout)
            }
        }
    }

    private func isAsking(_ step: SaveSyncReport.Step) -> Binding<Bool> {
        Binding(get: { asking == step }, set: { if !$0 && asking == step { asking = nil } })
    }

    /// Play, once the cloud's save is compared with this iPhone's (save_sync_report, SaveSyncReport): a save that changed on both sides is the player's pick, not the
    /// newer file's, and a cloud save that did not come is said so before the game starts without it.
    private func start() {
        dm_cloud_saves_env()   // DM_SAVE_SYNC from the picked folder, as the game's mount will read it (front_ios.m calls it again at the start)
        let folder = getenv("DM_SAVE_SYNC").map { String(cString: $0) }
        guard let folder, SaveSyncReport.syncEnabled(folder) else { go(nil); return }
        check += 1; checking = true; asking = nil
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.compare(folder: folder)
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveSyncReport.step(r) {
                case .play(let choice): go(choice)
                case let step: report = r; asking = step
                }
            }
        }
    }

    /// Blocks while the cloud's file downloads (SaveSyncReport.waitMs at most). nil: no report (the host then decides as it always did)
    private static func compare(folder: String) -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: main.m sets DM_SAVE and applies env.txt after that snapshot
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        let r = folder.withCString { save_sync_report(save, dm_save_title(), $0, SaveSyncReport.waitMs, &buf, buf.count) }
        guard r == 0 else {
            fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr)
            return nil
        }
        let line = String(cString: buf)
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    private func go(_ choice: String?) {
        asking = nil
        if let choice { setenv("DM_SAVE_SYNC_CHOICE", choice, 1); fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr) }
        play()
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let model = LauncherModel(file.settings)
    gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = DmHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
