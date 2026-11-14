import SwiftUI
import AppKit

struct PhotoMergeMenu: View {
    @Bindable var model: AppModel
    var body: some View {
        Button(L10n.text("merge.retouch.reopen",defaultValue:"Edit Saved Merge…")) { model.reopenEditableMerge() }.disabled(!model.canReopenEditableMerge)
        Divider()
        ForEach([PhotoMergeKind.panorama,.hdr,.hdrPanorama,.focus]) { kind in
            Button(kind.title+"…") { model.requestPhotoMerge(kind) }.disabled(!model.canMergePhotos || model.selection.count > kind.sourceLimit)
        }
        Divider()
        ForEach([PhotoMergeKind.average,.median,.additive,.lighten,.darken,.screen]) { kind in
            Button(kind.title+"…") { model.requestPhotoMerge(kind) }.disabled(!model.canMergePhotos || model.selection.count > kind.sourceLimit)
        }
    }
}

struct PhotoMergeSheet: View {
    @Bindable var session: PhotoMergeSession
    let completed: (MergeSaved) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L10n.text("merge.title", defaultValue:"Merge Photos")).font(.headline)
                Spacer()
                Text(L10n.text("merge.sourceCount", defaultValue:"\(session.inputs.count) originals")).font(.value).foregroundStyle(Theme.textSecondary)
            }
            Text(L10n.text("merge.originalsHint", defaultValue:"Uses uncropped originals and the first photo's white balance. Exposure, creative edits, local masks and rotation are not baked in. The result is a separate 32-bit float linear-sRGB TIFF or DNG, editable in Develop.")).font(.caption11).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal:false,vertical:true)
            HStack(alignment:.top,spacing:16) {
                controls.frame(width:300)
                VStack(alignment:.leading,spacing:8) {
                    if session.retouch.active {
                        MergeRetouchView(state:session.retouch,sourceCount:session.retouchSourceNames.count,enabled:!session.working,mat:mat)
                    } else {
                    GeometryReader { geometry in
                        ZStack {
                            mat.color
                            if let preview = session.preview {
                                Image(decorative:preview.image,scale:1).resizable().aspectRatio(contentMode:.fit)
                                    .frame(width:geometry.size.width,height:geometry.size.height)
                                    .accessibilityLabel(L10n.text("merge.previewImage", defaultValue:"Composite preview"))
                            } else {
                                Text(session.working ? session.phase : L10n.text("merge.previewHint", defaultValue:"Build a preview to inspect alignment and seams"))
                                    .font(.caption11).foregroundStyle(Color(nsColor:mat.textSecondary)).multilineTextAlignment(.center).padding(30)
                            }
                        }.clipped()
                    }.frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityIdentifier("merge-preview")
                    }
                    if let preview = session.preview {
                        Text(L10n.text("merge.canvasSize", defaultValue:"Canvas before crop: \(preview.width) × \(preview.height) px")).font(.caption11).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                    AdjustmentRow(label:L10n.text("merge.previewExposure", defaultValue:"Preview EV"),value:session.previewEV,range:-5...5,step:0.1,digits:1,
                        change:{ value,_ in session.previewEV = value },commit:{})
                        .disabled(session.preview == nil || session.working)
                    Text(L10n.text("merge.previewExposureHint", defaultValue:"Preview EV changes the display only; adjust the saved master's exposure in Develop.")).font(.caption11).foregroundStyle(Theme.textSecondary)
                }
            }.frame(maxHeight:.infinity)
            Seam()
            HStack(spacing:12) {
                Button(L10n.text("merge.chooseDestination", defaultValue:"Choose Destination…"),action:chooseDirectory).buttonStyle(.key).accessibilityIdentifier("merge-directory")
                Text(session.directory?.path ?? L10n.text("merge.noDestination", defaultValue:"Choose a folder for the new master"))
                    .font(.caption11).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength:0)
            }.disabled(session.working)
            HStack {
                Text(L10n.text("merge.filename", defaultValue:"Filename"))
                TextField(L10n.text("merge.filename", defaultValue:"Filename"),text:$session.filename).textFieldStyle(.instrument).frame(maxWidth:400).disabled(session.working)
                    .accessibilityIdentifier("merge-filename")
                Text(L10n.text("merge.noOverwrite", defaultValue:"Existing files are preserved")).font(.caption11).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            VStack(alignment:.leading,spacing:4) {
                Toggle(L10n.text("merge.stackWithSources", defaultValue:"Stack with Source Photos"),isOn:$session.stackWithSources)
                    .toggleStyle(.instrument).accessibilityIdentifier("merge-stack-with-sources")
                Text(L10n.text("merge.stackHint", defaultValue:"When enabled, the result is first and sources are collapsed. Only participating photos leave their old stacks; other members stay. Undo restores stacking and keeps the master."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
            }.disabled(session.working)
            if let error = session.error { Text(error).font(.caption11).foregroundStyle(Theme.warning).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("merge-error") }
            HStack(spacing:12) {
                if session.working {
                    ProgressView(value:session.progress).frame(width:140)
                    Text(session.phase).font(.caption11).lineLimit(1)
                }
                Spacer()
                Button(session.working ? L10n.text("app.cancel", defaultValue:"Cancel") : L10n.text("app.close", defaultValue:"Close")) {
                    if session.working { session.cancel() } else if session.retouch.hasChanges { confirmDiscard = true } else { dismiss() }
                }.buttonStyle(.key).keyboardShortcut(.cancelAction).accessibilityIdentifier("merge-close")
                if session.options.kind.supportsRetouch,session.preview != nil,!session.retouch.active {
                    Button(L10n.text("merge.retouch.start",defaultValue:"Refine Merge…"),action:session.startRetouch).buttonStyle(.key).disabled(session.working)
                        .accessibilityIdentifier("merge-retouch-start")
                }
                Button(L10n.text("merge.buildPreview", defaultValue:"Build Preview"),action:session.makePreview).buttonStyle(.key)
                    .disabled(session.working || session.inputs.isEmpty || session.retouch.active || session.reopening).accessibilityIdentifier("merge-build-preview")
                Button(L10n.text("merge.save", defaultValue:"Merge and Save")) { session.save(completion:completed) }.buttonStyle(PrimaryKeyStyle())
                    .disabled(session.working || session.retouch.pending || session.retouch.error != nil || session.preview == nil || session.directoryBookmark == nil || session.filename.isEmpty)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("merge-save")
            }
        }.padding(24).frame(width:1000,height:740).instrumentForm()
            .interactiveDismissDisabled(session.working || session.retouch.active)
            .confirmationDialog(L10n.text("merge.retouch.discardQuestion",defaultValue:"Discard unsaved merge corrections?"),isPresented:$confirmDiscard) {
                Button(L10n.text("merge.retouch.discard",defaultValue:"Discard Corrections"),role:.destructive) { dismiss() }
                Button(L10n.text("app.cancel",defaultValue:"Cancel"),role:.cancel) { }
            }
            .onChange(of:session.options) { session.invalidate() }
            .onChange(of:session.options.kind) { session.applyModeDefaults() }
            .onChange(of:session.options.masterFormat) { session.updateFilenameExtension() }
            .onChange(of:session.previewEV) { session.updateDisplay() }
            .onDisappear { session.cancel() }
    }
    private var controls: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:12) {
            if session.retouch.active {
                MergeRetouchControls(session:session,state:session.retouch)
                Text(L10n.text("merge.retouch.locked",defaultValue:"Source order and geometry are fixed during retouching. Comparison shows the projection canvas before boundary warp, fill and crop; these are applied when saving."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
                Seam()
            }
            Group {
            Picker(L10n.text("merge.mode", defaultValue:"Mode"),selection:$session.options.kind) {
                ForEach(PhotoMergeKind.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("merge-mode")
            if session.options.kind.isPanorama {
                Picker(L10n.text("merge.projection", defaultValue:"Projection"),selection:$session.options.projection) {
                    ForEach(MergeProjection.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("merge-projection")
                Toggle(L10n.text("merge.autoLevel", defaultValue:"Auto Level"),isOn:$session.options.autoLevel).toggleStyle(.instrument).accessibilityIdentifier("merge-auto-level")
                AdjustmentRow(label:L10n.text("merge.boundaryWarp", defaultValue:"Boundary Warp"),value:session.options.boundaryWarp,range:0...100,step:1,digits:0,unit:"%",
                    change:{ value,_ in session.options.boundaryWarp = value },commit:{})
                    .accessibilityIdentifier("merge-boundary-warp")
                Toggle(L10n.text("merge.fillEdges", defaultValue:"Fill Edges"),isOn:$session.options.fillEdges).toggleStyle(.instrument).accessibilityIdentifier("merge-fill-edges")
                Text(L10n.text("merge.finishHint", defaultValue:"Level estimates camera orientation. Warp stretches the boundary; fill diffuses nearby colours into gaps and may soften large empty areas.")).font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
            }
            if session.options.kind != .panorama {
                Toggle(session.options.kind == .hdrPanorama ? L10n.text("merge.alignBrackets", defaultValue:"Auto Align Brackets") : L10n.text("merge.align", defaultValue:"Auto Align"),isOn:$session.options.align).toggleStyle(.instrument).accessibilityIdentifier("merge-align")
            }
            if session.options.kind.isHDR {
                Picker(L10n.text("merge.deghost", defaultValue:"Deghost"),selection:$session.options.deghost) {
                    Text(L10n.text("merge.deghost.off", defaultValue:"Off")).tag(0)
                    Text(L10n.text("merge.deghost.low", defaultValue:"Low")).tag(1)
                    Text(L10n.text("merge.deghost.medium", defaultValue:"Medium")).tag(2)
                    Text(L10n.text("merge.deghost.high", defaultValue:"High")).tag(3)
                }.accessibilityIdentifier("merge-deghost")
            }
            if session.options.kind == .hdrPanorama {
                Picker(L10n.text("merge.bracketSize", defaultValue:"Frames per Position"),selection:$session.options.bracketSize) {
                    ForEach(2...9,id:\.self) { Text(String($0)).tag($0) }
                }.accessibilityIdentifier("merge-bracket-size")
                Text(L10n.text("merge.bracketHint", defaultValue:"Each consecutive group is one panorama position. Every position must have the same bracket count; order each complete group together.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            Toggle(L10n.text("merge.crop", defaultValue:"Crop Uncovered Edges"),isOn:$session.options.autoCrop).toggleStyle(.instrument).accessibilityIdentifier("merge-crop")
            Picker(L10n.text("merge.sourceSize", defaultValue:"Source Long Edge"),selection:$session.options.sourceLongEdge) {
                Text(L10n.text("merge.originalSize", defaultValue:"Original")).tag(0)
                ForEach([6000,4000,2000],id:\.self) { Text(L10n.text("merge.pixelSize", defaultValue:"\($0) px")).tag($0) }
            }.accessibilityIdentifier("merge-source-size")
            Picker(L10n.text("merge.masterFormat", defaultValue:"Master Format"),selection:$session.options.masterFormat) {
                ForEach(MergeMasterFormat.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("merge-master-format")
            if session.options.masterFormat == .dng {
                Text(L10n.text("merge.dngHint", defaultValue:"Float DNG masters reopen in Phosdeck. Some system image viewers cannot open this format; choose TIFF for those viewers.")).font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
            }
            SubgroupLabel(L10n.text("merge.order", defaultValue:"Source Order"))
            Text(session.options.kind == .focus ? L10n.text("merge.focusOrder", defaultValue:"Arrange in focus order, near to far or far to near.") : L10n.text("merge.orderHint", defaultValue:"Starts in capture/name order. Reorder complete brackets here if needed."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
                LazyVStack(alignment:.leading,spacing:5) {
                    ForEach(Array(session.inputs.enumerated()),id:\.element.photo.id) { index,input in
                        HStack(spacing:6) {
                            Text(String(index+1)).font(.value).foregroundStyle(Theme.textSecondary).frame(width:23,alignment:.trailing)
                            Text(input.photo.name).font(.caption11).lineLimit(1).truncationMode(.middle).help(input.photo.relativePath)
                            Spacer(minLength:0)
                            Button { session.move(index,by:-1) } label: { Image(systemName:"chevron.up") }.buttonStyle(.key(height:24,padding:6))
                                .disabled(index == 0).accessibilityLabel(L10n.text("merge.moveEarlier", defaultValue:"Move \(input.photo.name) earlier"))
                            Button { session.move(index,by:1) } label: { Image(systemName:"chevron.down") }.buttonStyle(.key(height:24,padding:6))
                                .disabled(index == session.inputs.count-1).accessibilityLabel(L10n.text("merge.moveLater", defaultValue:"Move \(input.photo.name) later"))
                        }
                    }
                }.padding(8)
                .background(Theme.inset)
            }.disabled(session.retouch.active || session.reopening)
        }.disabled(session.working)
        }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = L10n.text("merge.chooseFolder", defaultValue:"Use This Folder")
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            let lease = AccessLease(url:url); defer { withExtendedLifetime(lease) {} }
            session.directoryBookmark = try AccessLease.bookmark(url,readOnly:false); session.directory = url; session.error = nil
        } catch { session.error = error.localizedDescription }
    }
}
