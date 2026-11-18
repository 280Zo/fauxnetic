plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.aj.fauxnetic"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.aj280zo.fauxnetic"
        minSdk = 28
        ndk {
            abiFilters += "arm64-v8a"
        }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The JNI bridge EngineService uses to run the voice engine in its own process.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // The Play upload key: FAUXNETIC_UPLOAD_PASSWORD, with FAUXNETIC_UPLOAD_STORE (a PKCS12 file,
    // default <repo>/signing/upload.p12) and FAUXNETIC_UPLOAD_ALIAS (default "upload"). Without the
    // password, release builds are signed with the debug key.
    val uploadStore = System.getenv("FAUXNETIC_UPLOAD_PASSWORD")?.takeIf { it.isNotBlank() }?.let {
        System.getenv("FAUXNETIC_UPLOAD_STORE")?.takeIf { it.isNotBlank() }
            ?: rootProject.file("../../signing/upload.p12").path
    }
    signingConfigs {
        if (uploadStore != null) {
            create("upload") {
                storeFile = file(uploadStore)
                storeType = "PKCS12"
                storePassword = System.getenv("FAUXNETIC_UPLOAD_PASSWORD")
                keyAlias = System.getenv("FAUXNETIC_UPLOAD_ALIAS") ?: "upload"
                keyPassword = System.getenv("FAUXNETIC_UPLOAD_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (uploadStore != null) "upload" else "debug")
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
