plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.luong.adfree_tube"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.luong.adfree_tube"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10+: downloads are saved with MediaStore's RELATIVE_PATH.
        minSdk = maxOf(flutter.minSdkVersion, 29)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // CI signs with a fixed key from GitHub secrets so every build can be
    // installed as an update over the previous one. Without those variables
    // (e.g. local builds) it falls back to the machine's debug key.
    val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    // Only package native libraries (yt-dlp's Python, ffmpeg) for the
    // processors being built, e.g. `flutter build apk --target-platform
    // android-arm64` gives one arm64 APK instead of carrying all four.
    val targetPlatforms = (project.findProperty("target-platform") as String?)
        ?.split(",")
        ?.mapNotNull {
            mapOf(
                "android-arm64" to "arm64-v8a",
                "android-arm" to "armeabi-v7a",
                "android-x64" to "x86_64",
                "android-x86" to "x86",
            )[it.trim()]
        }
    if (!targetPlatforms.isNullOrEmpty()) {
        defaultConfig.ndk.abiFilters += targetPlatforms
    }

    packaging {
        // youtubedl-android runs Python and ffmpeg from the extracted native
        // library folder, so native libraries must be unpacked on install.
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (releaseKeystore != null) "release" else "debug"
            )
            // Keep rules for the download libraries (bug 14).
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // yt-dlp, Python, ffmpeg and QuickJS for downloads, as in the YT
    // Downloader Android app.
    val youtubedl = "0.18.1"
    implementation("io.github.junkfood02.youtubedl-android:library:$youtubedl")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$youtubedl")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
