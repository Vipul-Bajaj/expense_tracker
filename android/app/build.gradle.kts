plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

android {
    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    namespace = "app.vipulbajaj.expensetracker"
    // Google Play requires targeting a recent API level; pin it so the build
    // doesn't depend on whichever Flutter version happens to be installed.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = "27.1.12297006"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    signingConfigs {
        getByName("debug") {
            val debugKey = file("debug.keystore")
            if (debugKey.exists()) {
                storeFile = debugKey
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    defaultConfig {
        // Permanent once published on Google Play — never change this.
        applicationId = "app.vipulbajaj.expensetracker"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Release builds must be signed with the upload key from key.properties.
            // Debug-key fallback is only for CI/dev builds and must be opted into
            // explicitly, so a debug-signed build can never be uploaded by accident.
            signingConfig = when {
                keystorePropertiesFile.exists() -> signingConfigs.getByName("release")
                System.getenv("ALLOW_DEBUG_RELEASE_SIGNING") == "true" -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }

    gradle.taskGraph.whenReady {
        val buildsRelease = allTasks.any { it.name.contains("Release") }
        if (buildsRelease && signingConfigs.findByName("release") == null &&
            System.getenv("ALLOW_DEBUG_RELEASE_SIGNING") != "true") {
            throw GradleException(
                "Release signing is not configured. Create android/key.properties " +
                "(see README) or set ALLOW_DEBUG_RELEASE_SIGNING=true for a non-Play test build."
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:32.7.2"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.android.gms:play-services-auth:21.0.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
}

configurations.all {
    resolutionStrategy {
        force("androidx.core:core:1.15.0")
    }
}
