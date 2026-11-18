pluginManagement {
    repositories { google(); gradlePluginPortal(); mavenCentral() }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}

rootProject.name = "voip-android"
include(":core", ":runtime", ":system", ":testing")
