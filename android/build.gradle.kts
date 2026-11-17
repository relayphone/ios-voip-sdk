import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    base
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

subprojects {
    apply(plugin = "org.jetbrains.kotlin.jvm")
    apply(plugin = "java-library")
    apply(plugin = "maven-publish")

    group = "com.relayphone"
    version = rootDir.resolve("../VERSION").readText().trim()

    extensions.configure<KotlinJvmProjectExtension> {
        jvmToolchain(17)
        explicitApi()
    }
    tasks.withType<KotlinCompile>().configureEach {
        compilerOptions.allWarningsAsErrors.set(true)
    }
    extensions.configure<JavaPluginExtension> { withSourcesJar() }
    tasks.withType<Test>().configureEach {
        useJUnitPlatform()
        maxParallelForks = 1
    }
    extensions.configure<PublishingExtension> {
        publications.create<MavenPublication>("maven") {
            from(components["java"])
            artifactId = "voip-${project.name}"
        }
    }
}

tasks.check { dependsOn(subprojects.map { "${it.path}:check" }) }
