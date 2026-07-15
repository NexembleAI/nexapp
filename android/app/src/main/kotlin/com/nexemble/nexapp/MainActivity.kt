package com.nexemble.nexapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode

class MainActivity : FlutterActivity() {
    // Render into a TextureView instead of the default SurfaceView. A
    // SurfaceView shows black until a Flutter frame is drawn, which flashes on
    // a cold restart (the async init in main() runs before runApp) and when the
    // surface is recreated on resume from the login Custom Tab. A TextureView
    // shows the white window background during those gaps instead.
    override fun getRenderMode(): RenderMode = RenderMode.texture
}
