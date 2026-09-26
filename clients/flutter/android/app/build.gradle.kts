import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is supplied privately by the packaging command or CI.
// Never substitute the public debug key when release credentials are absent.
val releaseStore = providers.environmentVariable("ARVEIL_ANDROID_KEYSTORE")
val releaseStorePassword = providers.environmentVariable("ARVEIL_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = providers.environmentVariable("ARVEIL_ANDROID_KEY_ALIAS")
val releaseKeyPassword = providers.environmentVariable("ARVEIL_ANDROID_KEY_PASSWORD")

// Only a build with an update feed asks for the permission to install
// packages; stores and device policies may flag it. Flutter hands its
// dart-defines to Gradle as comma-separated Base64, from --dart-define and
// --dart-define-from-file alike.
val dartDefines = (findProperty("dart-defines") as String?).orEmpty()
    .split(",").filter { it.isNotEmpty() }
    .map { String(Base64.getDecoder().decode(it)) }
val updateFeed = listOf("ARVEIL_UPDATE_URL=", "ARVEIL_UPDATE_PUBLIC_KEY=").all { name ->
    dartDefines.any { it.startsWith(name) && it.length > name.length }
}

android {
    namespace = "io.github.ulzuhan.arveil"
    // flutter_secure_storage, which keeps the profile key in the Keystore,
    // requires compiling against 37. The Flutter SDK still defaults to 36.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.ulzuhan.arveil"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStore.isPresent) {
            create("distribution") {
                storeFile = file(releaseStore.get())
                storePassword = releaseStorePassword.get()
                keyAlias = releaseKeyAlias.get()
                keyPassword = releaseKeyPassword.get()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("distribution")
        }
    }
}

// Debug builds stay usable without secrets; every release build must be signed.
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        check(releaseStore.isPresent && releaseStorePassword.isPresent &&
            releaseKeyAlias.isPresent && releaseKeyPassword.isPresent) {
            "Release signing is missing. Use scripts/package_clients.py; see docs/CLIENT_RELEASES.md."
        }
    }
}

androidComponents {
    onVariants { variant ->
        if (updateFeed) variant.sources.manifests.addStaticManifestFile("src/updateFeed/AndroidManifest.xml")
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
    testImplementation("junit:junit:4.13.2")
}
