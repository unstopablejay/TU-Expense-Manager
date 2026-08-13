allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some Flutter plugins (another_telephony among them) still pin
// `jvmTarget = "1.8"`, while AGP 9 compiles their Java at 11 — and Kotlin fails
// the build when the two disagree. Nudge only those stale modules up to 11;
// anything already consistent (including :app at 17) is left alone.
//
// This has to be registered before the `evaluationDependsOn(":app")` below,
// which eagerly evaluates :app — `afterEvaluate` throws on a project that has
// already been evaluated.
subprojects {
    afterEvaluate {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            val jvmTarget = compilerOptions.jvmTarget
            if (jvmTarget.get() == org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8) {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
