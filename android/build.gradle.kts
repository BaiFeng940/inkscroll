// ★ 国内镜像加速：AGP / Kotlin / AndroidX 依赖统一走阿里云。
// google() / mavenCentral() 在本机被 TLS 中间人限速，换成镜像后构建快一个数量级。
// 若你在海外网络环境，可以删掉这段，恢复 google() + mavenCentral()。
allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        // 兜底：镜像缺包时回落到官方源
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

// ★ 统一插件模块的 compileSdk。
//
// 背景：Flutter 插件各自声明 compileSdk，很容易冲突。本仓库实测：
//   file_picker 按 android-34 编译，而 flutter_plugin_android_lifecycle
//   的 AAR 元数据要求依赖方 ≥ 36 → checkDebugAarMetadata 直接失败：
//     "Dependency ':flutter_plugin_android_lifecycle' requires libraries and
//      applications that depend on it to compile against version 36 or later"
//
// 这里把所有 Android 插件子工程的 compileSdk 抬到 36。
// compileSdk 只决定"能用哪些 API 编译"，不影响 minSdk（安装兼容性）
// 与 targetSdk（运行时行为），所以这样抬高是安全的。
//
// 注意：不能用 provider 覆盖的形式（plugins.withId { extensions.configure<...> }），
// 因为插件模块自己的 build.gradle 随后会再赋值一次，反而把我们覆盖掉。
// 必须在 evaluate 之后强制写入（Gradle 9 会有 deprecation 提示，可忽略）。
val pluginCompileSdk = 36

subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (androidExt != null) {
            val current = androidExt.compileSdkVersion?.removePrefix("android-")?.toIntOrNull()
            if (current == null || current < pluginCompileSdk) {
                androidExt.compileSdkVersion(pluginCompileSdk)
                logger.lifecycle("[compileSdk] ${project.name}: $current -> $pluginCompileSdk")
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
