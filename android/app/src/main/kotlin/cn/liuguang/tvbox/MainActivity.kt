package cn.liuguang.tvbox

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import cn.liuguang.engine.SourceEnginePlugin

class MainActivity : FlutterActivity() {
    private var sourceEngine: SourceEnginePlugin? = null
    private var sourceEngineOwner: FlutterEngine? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        sourceEngine?.close()
        sourceEngine = null
        sourceEngineOwner = null
        super.configureFlutterEngine(flutterEngine)
        sourceEngine = SourceEnginePlugin.register(flutterEngine, this)
        sourceEngineOwner = flutterEngine
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (sourceEngineOwner === flutterEngine) {
            sourceEngine?.close()
            sourceEngine = null
            sourceEngineOwner = null
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
