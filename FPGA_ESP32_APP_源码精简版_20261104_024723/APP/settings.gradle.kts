// 手机端构建入口。
// 版本矩阵：AGP 9.4.1 / Kotlin 2.4.20 / Gradle 9.7.1 / MIUIX 0.9.4。
pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "FpgaInstrument"
include(":app")
