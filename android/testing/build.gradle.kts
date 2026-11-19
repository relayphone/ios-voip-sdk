plugins { alias(libs.plugins.kotlin.serialization) }

dependencies {
    api(project(":runtime"))
    api(libs.coroutines.test)
    testImplementation(libs.serialization.json)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.withType<Test>().configureEach {
    val journeys = rootDir.resolve("../spec/journeys")
    val bridge = rootDir.resolve("../spec/bridge/fixtures")
    inputs.dir(journeys)
    inputs.dir(bridge)
    systemProperty("spec.journeys", journeys)
    systemProperty("spec.bridge", bridge)
}
