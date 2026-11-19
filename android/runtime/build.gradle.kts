dependencies {
    api(project(":core"))
    api(libs.coroutines.core)
}

dependencies {
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.coroutines.test)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../spec/bridge/fixtures/valid")
    inputs.dir(fixtures)
    systemProperty("spec.bridge", fixtures)
}
