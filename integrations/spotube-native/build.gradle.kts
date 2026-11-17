import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework
import org.jetbrains.kotlin.gradle.targets.jvm.KotlinJvmTarget

plugins { kotlin("multiplatform") version "2.2.21" }

kotlin {
    jvm()
    if (System.getProperty("os.name").startsWith("Mac")) {
        val bundle = XCFramework("FadedMusicCore")
        listOf(iosArm64(), iosSimulatorArm64(), iosX64()).forEach { target: KotlinNativeTarget ->
            target.binaries.framework {
                baseName = "FadedMusicCore"
                isStatic = true
                binaryOption("bundleId", "dk.fadedai.music")
                bundle.add(this)
            }
        }
    }
    sourceSets {
        commonMain.dependencies {
            implementation("io.github.yushosei:newpipe-extractor-kmp:1.3.0")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
        }
        commonTest.dependencies { implementation(kotlin("test")) }
    }
}

tasks.register<JavaExec>("smoke") {
    dependsOn("jvmMainClasses")
    val compilation = (kotlin.targets.getByName("jvm") as KotlinJvmTarget).compilations.getByName("main")
    classpath = files(compilation.output.allOutputs, configurations.getByName("jvmRuntimeClasspath"))
    mainClass.set("dk.fadedai.music.SmokeKt")
}
