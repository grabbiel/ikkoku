import SwiftUI

/// #440 measurement control, the growth check's positive control: with
/// `IKKOKU_PERF_FOCUS_PROBE=<n>` (1 to 64, read once at launch, a performance
/// trace option) the Studio inspector and the Maker panel each show `n` plain
/// buttons with the system focus effect at the top of their scroll view, and
/// show them again on every other action, the way that scroll view shows its
/// own controls again. #410 found that each show of such a control adds
/// AppKit state to the scroll view's group container that is never pruned,
/// so the probe must make `growth_check.py` fail. Unset (the default), the
/// count is 0 and both scroll views hold nothing more than before.
enum FocusProbe {
    static let count: Int = ProcessInfo.processInfo.environment["IKKOKU_PERF_FOCUS_PROBE"]
        .flatMap { Int($0) }.map { min(64, max(0, $0)) } ?? 0
}

/// The probe's buttons: the kind of control the workspace eye was before #410's
/// fix (a plain button with an image label), with the system focus effect.
struct FocusProbeButtons: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<FocusProbe.count, id: \.self) { _ in
                Button(action: {}) { Image(systemName: "circle") }.buttonStyle(.plain)
            }
        }
    }
}

/// The inspector's probe: kept mounted and hidden with `.inspectorHidden`, as
/// the kept sections are, flipping between shown and hidden at every
/// selection change.
struct InspectorFocusProbe: View {
    let model: StudioModel
    @State private var flips = 0

    var body: some View {
        FocusProbeButtons()
            .inspectorHidden(flips % 2 == 1)
            .onChange(of: model.selection) { flips += 1 }
    }
}
