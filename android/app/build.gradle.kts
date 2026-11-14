import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing for Chesster. Values come from environment variables (CI)
// or android/key.properties (local, gitignored):
//   CHESSTER_KEYSTORE / storeFile           path to the .jks keystore
//   CHESSTER_KEYSTORE_PASSWORD / storePassword
//   CHESSTER_KEY_ALIAS / keyAlias
//   CHESSTER_KEY_PASSWORD / keyPassword
// Without them, release builds fall back to the debug key so they still
// install for local testing (they cannot update a release-signed install).
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingValue(env: String, property: String): String? =
    System.getenv(env)?.takeIf { it.isNotBlank() }
        ?: keyProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseKeystorePath = signingValue("CHESSTER_KEYSTORE", "storeFile")
val releaseStorePassword = signingValue("CHESSTER_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("CHESSTER_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("CHESSTER_KEY_PASSWORD", "keyPassword")
val releaseSigningValues = listOf(
    releaseKeystorePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)

require(releaseSigningValues.all { it == null } || releaseSigningValues.all { it != null }) {
    "Set CHESSTER_KEYSTORE, CHESSTER_KEYSTORE_PASSWORD, CHESSTER_KEY_ALIAS and " +
        "CHESSTER_KEY_PASSWORD (or all four key.properties entries) together."
}

val maiaRuntimeVersion = "1.24.3"

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:$maiaRuntimeVersion")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

android {
    namespace = "com.dash1971.maia_chess"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Chesster installs alongside upstream Mobile Maia. The Kotlin
        // package/namespace intentionally stays com.dash1971.maia_chess.
        applicationId = "com.chesster.dojo"
        // Unflavored Stable keeps the canonical F-Droid build command.
        // The shared native transport gates experimental boards on this value.
        buildConfigField("String", "FLAVOR", "\"stable\"")
        buildConfigField("String", "MAIA_RUNTIME_VERSION", "\"$maiaRuntimeVersion\"")
        buildConfigField("String", "MAIA_MODEL_ASSET", "\"flutter_assets/assets/models/maia3-79m.onnx\"")
        buildConfigField("String", "MAIA_MODEL_FILE", "\"maia3-79m-3454b03a-sha256.onnx\"")
        buildConfigField("long", "MAIA_MODEL_BYTES", "316034244L")
        buildConfigField("String", "MAIA_MODEL_SHA256", "\"3454b03ae78baa64a87b345fdb1a457265d912caec531039b074f07eda0d8010\"")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (releaseKeystorePath != null) {
            create("chessterRelease") {
                storeFile = rootProject.file(releaseKeystorePath)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("chessterRelease")
                ?: signingConfigs.getByName("debug")
            // Remove unused Java/Kotlin bytecode, including Flutter's dormant
            // deferred-component bridge. JNI/reflection-sensitive ONNX classes
            // remain protected by the explicit rules in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

// Fail before Flutter copies assets: GitHub ZIP downloads and incomplete LFS
// clones otherwise produce an installable APK with a tiny text pointer as Maia.
val verifyMaiaModel by tasks.registering {
    val model = rootProject.file("../assets/models/maia3-79m.onnx")
    inputs.file(model)
    doLast {
        require(model.isFile && model.length() == 316_034_244L) {
            "Maia model missing or wrong size. Run git lfs install && git lfs pull."
        }
        val digest = MessageDigest.getInstance("SHA-256")
        model.inputStream().buffered().use { stream ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
        require(sha256 == "3454b03ae78baa64a87b345fdb1a457265d912caec531039b074f07eda0d8010") {
            "Maia model SHA-256 mismatch. Restore the pinned Git LFS object."
        }
    }
}
tasks.matching { it.name == "preBuild" || it.name.startsWith("compileFlutterBuild") }.configureEach {
    dependsOn(verifyMaiaModel)
}
