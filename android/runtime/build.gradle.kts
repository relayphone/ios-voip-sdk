dependencies {
    api(project(":core"))
    api(libs.coroutines.core)
}

kotlin.sourceSets.test { kotlin.srcDir(rootDir.resolve("../expo/android/src/bridge/kotlin")) }
tasks.processTestResources {
    from(rootDir.resolve("../spec")) {
        include("bridge.schema.json", "model.schema.json", "v1/model.schema.json")
        into("voip")
    }
}

dependencies {
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.coroutines.test)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../spec/bridge/fixtures")
    inputs.dir(fixtures)
    systemProperty("spec.bridge", fixtures.resolve("valid"))
}
