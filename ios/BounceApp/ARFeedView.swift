import ARKit
import SceneKit
import SwiftUI

/// Shows the camera feed of the shared AR session (ARSCNView draws it; nothing else is rendered in 3-D).
struct ARFeedView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.scene = SCNScene()
        v.automaticallyUpdatesLighting = false
        v.rendersCameraGrain = false
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
