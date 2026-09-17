import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit)
    // Test-only: parses the shared golden vectors. Not used by production code.
    testImplementation(libs.kotlinx.serialization.json)
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.withType<Test>().configureEach {
    // Golden vectors live at the repository root and are shared with the iOS test target.
    systemProperty("airchat.testdata.dir", rootProject.file("../testdata").absolutePath)
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = false
    }
}