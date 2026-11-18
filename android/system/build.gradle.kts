plugins {
    alias(libs.plugins.android.library)
    `maven-publish`
}

android {
    namespace = "com.relayphone.voip.system"
    compileSdk {
        version = release(37)
    }
    buildToolsVersion = "36.0.0"

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") { withSourcesJar() }
    }
}

kotlin {
    explicitApi()
    compilerOptions.allWarningsAsErrors.set(true)
}

dependencies {
    api(project(":runtime"))
    implementation(libs.core.telecom)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.coroutines.test)
    testRuntimeOnly(libs.junit.launcher)
    androidTestImplementation(libs.androidx.test.runner)
}

afterEvaluate {
    publishing {
        publications.create<MavenPublication>("maven") {
            from(components["release"])
            artifactId = "voip-system"
        }
    }
}
