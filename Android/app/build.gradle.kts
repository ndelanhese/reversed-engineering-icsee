plugins { id("com.android.application") }
android {
    namespace = "io.github.ndelanhese.reversedicsee"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    buildToolsVersion = "37.0.0"
    ndkVersion = "29.0.14206865"
    defaultConfig {
        applicationId = "io.github.ndelanhese.reversedicsee"
        minSdk = 28
        targetSdk = 37
        versionCode = 4
        versionName = "0.1.0-alpha.4"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildTypes {
        release { isMinifyEnabled = false }
    }
    packaging { jniLibs { useLegacyPackaging = false } }
    androidResources { ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:.*:CVS:thumbs.db:picasa.ini:*~:lua:hrtfs" }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation("org.videolan.android:libvlc-all:3.7.7")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
