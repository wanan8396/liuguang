import java.util.Properties
import java.util.zip.ZipFile

plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }

val localProperties = Properties().apply {
    val propertiesFile = rootProject.file("local.properties")
    if (propertiesFile.isFile) propertiesFile.inputStream().use { load(it) }
}
// Match the Flutter Gradle plugin's SDK precedence to avoid mixing engine revisions.
val flutterHome = (findProperty("flutter.sdk") as? String)?.takeIf { it.isNotBlank() }
    ?: localProperties.getProperty("flutter.sdk")?.takeIf { it.isNotBlank() }
    ?: providers.environmentVariable("FLUTTER_ROOT").orNull?.takeIf { it.isNotBlank() }
    ?: throw GradleException("Flutter SDK not found: set FLUTTER_ROOT or flutter.sdk in android/local.properties")
val flutterJar = file("$flutterHome/bin/cache/artifacts/engine/android-x64/flutter.jar")
if (!flutterJar.isFile || !flutterJar.canRead()) {
    throw GradleException("Android Flutter embedding not found or unreadable: $flutterJar. Run flutter precache --android.")
}
try {
    ZipFile(flutterJar).use { jar ->
        if (jar.getEntry("io/flutter/embedding/engine/FlutterEngine.class") == null ||
            jar.getEntry("io/flutter/plugin/common/BinaryMessenger.class") == null) {
            throw GradleException("Not an Android Flutter embedding JAR: $flutterJar. Run flutter precache --android.")
        }
    }
} catch (e: java.io.IOException) {
    throw GradleException("Unable to read Android Flutter embedding JAR: $flutterJar", e)
}
val ciEmulator = providers.gradleProperty("ciEmulator").map {
    when (it) {
        "true" -> true
        "false" -> false
        else -> throw GradleException("ciEmulator must be true or false, got: $it")
    }
}.getOrElse(false)
val ciFlutterEngineVersion = if (ciEmulator) {
    val engineStamp = file("$flutterHome/bin/cache/engine.stamp")
    if (!engineStamp.isFile || !engineStamp.canRead()) {
        throw GradleException("Flutter engine stamp not found or unreadable: $engineStamp")
    }
    val revision = engineStamp.readText().trim()
    if (revision.isEmpty()) throw GradleException("Flutter engine stamp is empty: $engineStamp")
    "1.0.0-$revision"
} else null

android {
    namespace = "cn.liuguang.engine"
    compileSdk = 36
    defaultConfig { minSdk = 24; consumerProguardFiles("consumer-rules.pro"); testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17; isCoreLibraryDesugaringEnabled = true }
    testOptions { unitTests.isReturnDefaultValues = true }
}

// Only the CI debug test host runs without the ARM-only QuickJS binaries.
// A normal release, including one built with -PciEmulator=true, retains them.
androidComponents {
    if (ciEmulator) {
        onVariants(selector().withBuildType("debug")) { variant ->
            val armQuickJs = listOf(
                "**/arm64-v8a/libquickjs-wrapper.so",
                "**/armeabi-v7a/libquickjs-wrapper.so",
            )
            variant.packaging.jniLibs.excludes.addAll(armQuickJs)
            variant.androidTest?.packaging?.jniLibs?.excludes?.addAll(armQuickJs)
        }
    }
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
dependencies {
    compileOnly(files(flutterJar))
    if (ciFlutterEngineVersion != null) {
        // The library test host needs the embedding at runtime too; compileOnly is not packaged.
        // Both artifacts use the SDK engine stamp, as does Flutter's own Gradle plugin.
        add("debugImplementation", "io.flutter:flutter_embedding_debug:$ciFlutterEngineVersion")
        add("debugRuntimeOnly", "io.flutter:x86_64_debug:$ciFlutterEngineVersion")
        androidTestImplementation("io.flutter:flutter_embedding_debug:$ciFlutterEngineVersion")
        androidTestRuntimeOnly("io.flutter:x86_64_debug:$ciFlutterEngineVersion")
    }
    // Keep the Android platform adapters; 5.4 supports SDK 36 and the host WebSocket API.
    implementation("com.squareup.okhttp3:okhttp-android:5.4.0")
    implementation("androidx.core:core:1.16.0")
    implementation("org.jsoup:jsoup:1.18.3")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("com.google.guava:guava:33.4.0-android")
    implementation("com.orhanobut:logger:2.2.0")
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    implementation(files("libs/quickjs-wrapper-5e191aa.jar"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
