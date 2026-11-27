plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.knockapp.knock"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Prototype id, separate from the earlier test builds so it installs
        // even if an old copy signed with another key is still on the phone.
        applicationId = "com.knockapp.prototype"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        // Android lint crashes on the image_picker plugin under the
        // release "lint vital" check. Run lint separately instead.
        checkReleaseBuilds = false
        abortOnError = false
    }

    // Prototype-only signing key, committed on purpose so every CI build has
    // the same signature and a new APK installs over the previous one.
    // NOT for the Play Store: production uses a private upload key.
    signingConfigs {
        create("prototype") {
            storeFile = file("prototype.jks")
            storePassword = "knockproto"
            keyAlias = "knockproto"
            keyPassword = "knockproto"
            // v1 too, for older or vendor package installers.
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("prototype")
        }
        release {
            signingConfig = signingConfigs.getByName("prototype")
            // Prototype: keep R8 shrinking off until keep-rules for the
            // plugins are reviewed. Turn on for the store build.
            isMinifyEnabled = false
            isShrinkResources = false
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
