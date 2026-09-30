# FLEX integration boundary

The handoff includes FLEX source ZIP and a separately working FLEX dylib. The source metadata identifies FLEX **5.22.10** (`FLEX.podspec`) and its BSD license (`LICENSE`). The supplied code includes an interactive hierarchy tree and SceneKit-backed snapshot/3D explorer; these are inspection UI features, not a demonstrated structured export interface.

UniversalUIInspector does **not** compile, link, or bundle FLEX source. Its visited-screen exporter uses its own bounded UIKit traversal and can operate with FLEX absent. It excludes windows whose class/root names identify FLEX and omits FLEX-named view subtrees; where a FLEX subtree is found in the host window, the screenshot must be marked/suppressed rather than presented as uncontaminated. No private FLEX object API is a dependency. No export of FLEX's 3D scene is claimed.

The app-level view report describes visible UIKit objects at capture time. SwiftUI hosting internals are runtime UIKit representations only; this does not reconstruct original SwiftUI declarations. Unity/Metal canvases are not guaranteed to appear in UIKit trees or screenshots.
