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
    val transitions = rootDir.resolve("../spec/transitions.json")
    inputs.dir(fixtures)
    inputs.file(transitions)
    systemProperty("spec.fixtures", fixtures)
    systemProperty("spec.transitions", transitions)
}
