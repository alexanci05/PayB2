import groovy.json.JsonSlurper
import java.nio.ByteBuffer
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Use the same compile-time environment as Dart before FirebaseInitProvider runs.
val dartDefines = providers.gradleProperty("dart-defines").orNull
    ?.takeIf { it.isNotEmpty() }
    ?.split(",")
    ?.mapIndexed { index, encoded ->
        try {
            require(encoded.isNotEmpty()) { "Empty dart-define." }
            Charsets.UTF_8.newDecoder()
                .decode(ByteBuffer.wrap(Base64.getDecoder().decode(encoded)))
                .toString()
        } catch (exception: Exception) {
            throw GradleException("Invalid Base64/UTF-8 dart-define at index $index.", exception)
        }
    }.orEmpty()
val environmentDefines = dartDefines.filter { it.substringBefore("=") == "FIREBASE_ENV" }
require(environmentDefines.size <= 1) { "FIREBASE_ENV must not be defined more than once." }
val firebaseEnvironment = environmentDefines.singleOrNull()?.let { define ->
    require(define.contains("=")) { "FIREBASE_ENV must have an explicit value." }
    define.substringAfter("=")
} ?: "emulator"
require(firebaseEnvironment == "emulator" || firebaseEnvironment == "production") {
    "FIREBASE_ENV must be emulator or production."
}

// Production release signing is opt-in and never falls back to the debug key.
// Paths in key.properties are relative to android/, or absolute.
val releaseSigningFile = rootProject.file("key.properties")
val releaseSigning = Properties().apply {
    if (firebaseEnvironment == "production" && releaseSigningFile.isFile) {
        releaseSigningFile.inputStream().use { load(it) }
    }
}
val releaseStoreFile = releaseSigning.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
// Resolved below from AGP, so customized debug keystore paths are also rejected.
var signingDebugStoreFile: File? = null
val validateProductionReleaseSigning = tasks.register("validateProductionReleaseSigning") {
    group = "verification"
    description = "Reject production release builds without explicit private signing configuration."
    onlyIf { firebaseEnvironment == "production" }
    doLast {
        require(releaseSigningFile.isFile) {
            "Production release requires android/key.properties. Use android/key.properties.example as a template."
        }
        listOf("storeFile", "storePassword", "keyAlias", "keyPassword").forEach { key ->
            require(!releaseSigning.getProperty(key).isNullOrBlank()) {
                "Production release signing is missing $key in android/key.properties."
            }
        }
        val store = requireNotNull(releaseStoreFile) { "Production release keystore is not configured." }
        require(store.isFile && store.canRead()) {
            "Production release keystore is missing or unreadable."
        }
        require(!releaseSigning.getProperty("keyAlias").equals("androiddebugkey", ignoreCase = true)) {
            "The Android debug key cannot sign a production release."
        }
        require(store.canonicalFile != signingDebugStoreFile?.canonicalFile) {
            "The Android debug keystore cannot sign a production release."
        }
    }
}

fun Map<*, *>.requiredString(key: String): String =
    (this[key] as? String)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("Missing or invalid google-services.json field: $key")

android {
    namespace = "com.example.payb2"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "29.0.13599879"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.payb2"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        manifestPlaceholders["firebaseUsesCleartextTraffic"] =
            (firebaseEnvironment == "emulator").toString()

        val firebaseResources = if (firebaseEnvironment == "emulator") {
            mapOf(
                "project_id" to "demo-payb2",
                "gcm_defaultSenderId" to "1234567890",
                "google_app_id" to "1:1234567890:android:0000000000000000000000",
                "google_api_key" to "AIzaSyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "google_storage_bucket" to "demo-payb2.appspot.com",
            )
        } else {
            // Never read production configuration for an emulator build.
            val config = JsonSlurper().parse(file("google-services.json")) as? Map<*, *>
                ?: throw GradleException("Invalid production google-services.json object.")
            val projectInfo = config["project_info"] as? Map<*, *>
                ?: throw GradleException("Missing production Firebase project_info.")
            val clients = config["client"] as? List<*>
                ?: throw GradleException("Missing production Firebase clients.")
            val matchingClients = clients.mapNotNull { it as? Map<*, *> }.filter { client ->
                val info = client["client_info"] as? Map<*, *>
                val androidInfo = info?.get("android_client_info") as? Map<*, *>
                androidInfo?.get("package_name") == applicationId
            }
            val client = matchingClients.singleOrNull()
                ?: throw GradleException("Expected one Firebase client for $applicationId.")
            val clientInfo = client["client_info"] as? Map<*, *>
                ?: throw GradleException("Missing production Firebase client_info.")
            val apiKeys = client["api_key"] as? List<*>
                ?: throw GradleException("Missing production Firebase api_key.")
            val apiKey = (apiKeys.firstOrNull() as? Map<*, *>)?.requiredString("current_key")
                ?: throw GradleException("Missing production Firebase current_key.")
            val projectId = projectInfo.requiredString("project_id")
            val senderId = projectInfo.requiredString("project_number")
            val appId = clientInfo.requiredString("mobilesdk_app_id")
            require(!projectId.startsWith("demo-")) {
                "Production Firebase configuration cannot use a demo project."
            }
            require(appId.startsWith("1:$senderId:android:")) {
                "Production Firebase app ID does not match its Android project."
            }
            mutableMapOf(
                "project_id" to projectId,
                "gcm_defaultSenderId" to senderId,
                "google_app_id" to appId,
                "google_api_key" to apiKey,
                "google_storage_bucket" to projectInfo.requiredString("storage_bucket"),
            ).apply {
                val oauthClients = when (val oauth = client["oauth_client"]) {
                    null -> emptyList<Any?>()
                    is List<*> -> oauth
                    else -> throw GradleException("Invalid production Firebase oauth_client.")
                }
                oauthClients.mapNotNull { it as? Map<*, *> }
                    .firstOrNull { (it["client_type"] as? Number)?.toInt() == 3 }
                    ?.let { put("default_web_client_id", it.requiredString("client_id")) }
            }
        }
        firebaseResources.forEach { (name, value) -> resValue("string", name, value) }
    }

    signingDebugStoreFile = signingConfigs.getByName("debug").storeFile
    signingConfigs {
        if (firebaseEnvironment == "production") {
            create("productionRelease") {
                storeFile = releaseStoreFile
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (firebaseEnvironment == "production") "productionRelease" else "debug",
            )
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" || it.name == "validateSigningRelease" }
    .configureEach { dependsOn(validateProductionReleaseSigning) }

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
