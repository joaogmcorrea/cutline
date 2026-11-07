// Choosing the color profiles, as in Illustrator (the conversions are in Model/ColorConversion.swift):
// - Cutline › Settings… › Color (also Edit › Color Settings…): the CMYK profile of the documents without their own and
//   the RGB working space (`ColorSettingsSection`);
// - Edit › Assign Profile…: the document's own CMYK profile, saved in the .cutline (`AssignProfileWindow`);
// - Load Profile…: a .icc/.icm from anywhere joins the lists (`ProfileLoader`);
// - without a CMYK profile (the default), a warning at the foot of the tools and in the Color panel says the print may
//   look different from the screen (`NoProfileWarning`); a profile missing on this Mac is said in the window's notice.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Document {
    /// Edit › Assign Profile…: the same CMYK numbers read in another profile (the screen and the print change; the
    /// numbers don't, as Illustrator's Assign Profile). nil = the app's; `.none` = no profile. One undo step.
    func assignProfile(_ profile: ColorProfile?) {
        guard profile != colorProfile else { return }
        registrar()
        colorProfile = profile
    }

    /// The window's notice when the CMYK profile in use isn't on this Mac (the document came from another one, or the file
    /// was moved): Generic CMYK takes its place.
    var missingProfileNotice: String? {
        let colors = colors
        guard colors.cmykMissing else { return nil }
        return String(localized: "The color profile “\(colors.cmykProfile.name)” isn’t on this Mac: the colors show and print with Generic CMYK until it’s installed or another one is assigned (Edit › Assign Profile…).")
    }
}

extension ColorProfile {
    /// The name in the menus.
    var title: String { isNone ? String(localized: "No Color Profile") : name }
}

/// Load Profile…: the open panel for a .icc/.icm; the profile joins the lists (where it is: Cutline doesn't copy it).
/// `model` nil takes either (Settings: a CMYK one goes to the CMYK profile, an RGB one to the working space).
enum ProfileLoader {
    static func choose(_ model: ColorModel?) -> (ColorProfile, ColorModel)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["icc", "icm"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = switch model {
        case .cmyk: String(localized: "Choose a CMYK color profile (.icc or .icm).")
        case .rgb: String(localized: "Choose an RGB color profile (.icc or .icm).")
        case nil: String(localized: "Choose a CMYK or RGB color profile (.icc or .icm).")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let loaded = ColorSettings.shared.load(url), model == nil || loaded.1 == model else {
            let alert = NSAlert()
            alert.messageText = switch model {
            case .cmyk: String(localized: "This file isn’t a CMYK color profile.")
            case .rgb: String(localized: "This file isn’t an RGB color profile.")
            case nil: String(localized: "This file isn’t a CMYK or RGB color profile.")
            }
            alert.informativeText = String(localized: "Choose an ICC profile for printing (CMYK) or an RGB working space.")
            alert.runModal()
            return nil
        }
        return loaded
    }
}

/// Cutline › Settings… › Color.
struct ColorSettingsSection: View {
    private var settings = ColorSettings.shared

    var body: some View {
        Section("Color") {
            let cmykList = [ColorProfile.none] + ColorProfiles.available(.cmyk, loaded: settings.loaded)
            Picker("CMYK profile", selection: Binding(get: { settings.cmyk }, set: { settings.setCMYK($0) })) {
                ProfileOptions(list: cmykList, chosen: settings.cmyk)
            }
            Picker("RGB working space", selection: Binding(get: { settings.rgb }, set: { settings.setRGB($0) })) {
                ProfileOptions(list: ColorProfiles.available(.rgb, loaded: settings.loaded), chosen: settings.rgb)
            }
            .disabled(settings.cmyk.isNone)
            LabeledContent("") {
                Button("Load Profile…") {
                    if let (profile, model) = ProfileLoader.choose(nil) {
                        if model == .cmyk { settings.setCMYK(profile) } else { settings.setRGB(profile) }
                    }
                }
            }
            let colors = settings.converter()
            if colors.cmykMissing || colors.rgbMissing {
                Label(colors.cmykMissing
                      ? String(localized: "“\(settings.cmyk.name)” isn’t on this Mac: Generic CMYK is used in its place.")
                      : String(localized: "“\(settings.rgb.name)” isn’t on this Mac: sRGB is used in its place."), image: .warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(settings.cmyk.isNone
                 ? "Without a profile, the screen uses a simple conversion and the print can look different. With one (as in Illustrator’s Color Settings), the screen shows the colors as they print, and RGB, HSL, hex and imported RGB colors convert through it. Documents can have their own (Edit › Assign Profile…)."
                 : "The screen shows the colors as this profile prints them; RGB, HSL, hex and imported RGB colors convert through it. Documents can have their own (Edit › Assign Profile…).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { ColorProfiles.refresh() }
    }
}

/// The menu items of a profile picker: the list, plus the chosen one if it isn't in it (missing on this Mac).
private struct ProfileOptions: View {
    let list: [ColorProfile]
    let chosen: ColorProfile

    var body: some View {
        ForEach(list) { Text(verbatim: $0.title).tag($0) }
        if !list.contains(chosen) {
            Divider()
            Text("\(chosen.name) (missing)").tag(chosen)
        }
    }
}

/// The window's part: the Assign Profile sheet (Edit › Assign Profile…, the warnings' button) and, on opening, the notice
/// of a CMYK profile missing on this Mac.
struct AssignProfileSheet: ViewModifier {
    let doc: Document
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $open) { AssignProfileWindow(doc: doc) }
            .onChange(of: doc.assignProfileRequest) { _, _ in open = true }
            .onAppear {
                if Feature.colorProfiles.isOn, let missing = doc.missingProfileNotice {
                    doc.notice = doc.notice.map { "\($0) \(missing)" } ?? missing
                }
                #if DEBUG
                if DebugHooks.openAssignProfile { open = true }
                #endif
            }
    }
}

/// Edit › Assign Profile…: as Illustrator's, the app's profile, no profile or one of the list.
struct AssignProfileWindow: View {
    @Bindable var doc: Document
    @Environment(\.dismiss) private var dismiss
    private var settings = ColorSettings.shared

    private enum Choice: Hashable { case app, none, profile }
    @State private var choice = Choice.app
    @State private var profile = ColorProfile.genericCMYK
    @State private var list: [ColorProfile] = []

    init(doc: Document) {
        self.doc = doc
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assign Profile").font(.headline)
            Text("The CMYK numbers stay the same; the profile says what ink they mean, so the screen and the print change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Profile", selection: $choice) {
                Text("As in Settings: \(settings.cmyk.title)").tag(Choice.app)
                Text("No color profile (simple conversion)").tag(Choice.none)
                Text("Profile:").tag(Choice.profile)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Picker("Profile", selection: $profile) {
                    ProfileOptions(list: list, chosen: profile)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button("Load Profile…") {
                    if let (loaded, _) = ProfileLoader.choose(.cmyk) {
                        list = ColorProfiles.available(.cmyk, loaded: settings.loaded)
                        profile = loaded
                        choice = .profile
                    }
                }
            }
            .disabled(choice != .profile)
            .padding(.leading, 20)
            if let notice = doc.missingProfileNotice {
                Label(notice, image: .warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    doc.assignProfile(choice == .app ? nil : choice == .none ? ColorProfile.none : profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            ColorProfiles.refresh()
            list = ColorProfiles.available(.cmyk, loaded: settings.loaded)
            switch doc.colorProfile {
            case nil: choice = .app
            case .some(let own) where own.isNone: choice = .none
            case .some(let own):
                choice = .profile
                profile = own
            }
        }
    }
}

/// The warning that, without a CMYK profile, the screen uses a simple conversion and the print can look different.
/// `compact`: only the icon (the foot of the tools); otherwise the sentence and the button (the Color panel). With a
/// profile, the compact form shows nothing and the full one names the profile.
struct NoProfileWarning: View {
    @Bindable var doc: Document
    var compact = false

    var body: some View {
        let colors = doc.colors
        if compact {
            if colors.unmanaged || colors.cmykMissing {
                Button { doc.assignProfileRequest += 1 } label: {
                    Image(.warning).resizable().frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help(colors.unmanaged
                      ? String(localized: "No color profile: the screen uses a simple conversion and the print can look different. Click to assign one.")
                      : doc.missingProfileNotice ?? "")
            }
        } else if colors.unmanaged || colors.cmykMissing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(.warning).resizable().frame(width: 12, height: 12).foregroundStyle(.orange)
                    Text(colors.unmanaged ? "No color profile: the print can look different from the screen."
                         : "The color profile is missing on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Assign Profile…") { doc.assignProfileRequest += 1 }
                    .controlSize(.small)
                    .padding(.leading, 18)
            }
            .font(.caption)
        } else {
            Text("Profile: \(colors.cmykProfile.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(colors.cmykProfile.path ?? colors.cmykProfile.name)
        }
    }
}
