import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is supplied outside the repository: `android/key.properties`
// locally, or LIUGUANG_* environment variables in CI. Without either, the build
// stays debug-signed so `flutter run --release` keeps working.
val signingProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingValue(key: String, environment: String): String? =
    (signingProperties.getProperty(key)?.takeIf { it.isNotBlank() })
        ?: System.getenv(environment)?.takeIf { it.isNotBlank() }

val releaseStorePath = signingValue("storeFile", "LIUGUANG_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "LIUGUANG_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "LIUGUANG_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "LIUGUANG_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStorePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

android {
    namespace = "cn.liuguang.tvbox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.liuguang.tvbox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Keep local `flutter run --release` usable without a keystore.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(project(":source_engine"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
