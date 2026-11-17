plugins {
    alias(libs.plugins.kotlin.serialization)
}

dependencies {
    implementation(libs.coroutines.core)
    api(libs.serialization.json)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../spec/fixtures")
    inputs.dir(fixtures)
    systemProperty("spec.fixtures", fixtures)
}
