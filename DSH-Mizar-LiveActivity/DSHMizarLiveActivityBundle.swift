//
//  DSHMizarLiveActivityBundle.swift
//  DSH-Mizar-LiveActivity
//
//  The extension's entry point.
//
//  A `WidgetBundle` rather than a bare `Widget` because that is what an extension
//  with a Live Activity is: the bundle is the extension's `@main`, and the
//  activity configuration inside it is matched to the app's request by the
//  attributes type. There is no kind string to keep in step between the two
//  processes -- `DSHMizarActivityAttributes`, in MizarKit, is the whole of the
//  agreement.
//

import SwiftUI
import WidgetKit

@main
struct DSHMizarLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DSHMizarLiveActivityWidget()
    }
}
