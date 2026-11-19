package com.inkscroll.reader

import android.app.Activity
import android.os.Build
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import kotlin.math.abs

/**
 * 高刷新率（120Hz / 144Hz）适配。
 *
 * ## 为什么必须显式请求
 *
 * 实测（vivo V2417A / Android 16 / OriginOS 6）：
 *
 * ```
 * mActiveModeId=4                 // 掉到了 60Hz 那一档
 * mActiveRenderFrameRate=60.0     // 实际就是 60fps
 * requestedFrameRate: {0.00 Hz FrameRateCompatibility::Default FrameRateCategory::NoPreference}
 * mUserPreferredModeId=1          // 系统偏好明明是 120Hz
 * supportedRefreshRates [120, 144, 90, 60]
 * ```
 *
 * 注意 `requestedFrameRate` 是 **0.00 Hz / NoPreference** —— 也就是
 * **没有任何人调用过 `Surface.setFrameRate()`**。
 * 系统于是保守地给了 60Hz，哪怕屏幕支持 144Hz、用户也把系统设成了 120Hz。
 *
 * 这是国产 ROM（OriginOS / ColorOS / HyperOS 等）的普遍行为：
 * **应用不主动声明，就按 60Hz 处理**，以免耗电。
 *
 * ## 这里怎么做
 *
 * 两条路一起上，因为不同 ROM 认的 API 不一样：
 *
 * 1. **`Window.setPreferredDisplayModeId`**（API 23+）
 *    直接把窗口切到"同分辨率下最高刷新率"的那一档显示模式。
 *    国产 ROM 对这个支持最好。
 *
 * 2. **`Surface.setFrameRate`**（API 30+，官方推荐）
 *    在真正绘制的 Surface 上声明帧率。Flutter 的绘制面在
 *    `FlutterSurfaceView`（`SurfaceView` 子类）里，而 `FlutterView`
 *    只是个 `FrameLayout`、没有暴露访问器，所以需要**遍历子视图**去拿。
 *    Surface 要等首帧渲染后才有效，因此用
 *    `addOnFirstFrameRenderedListener` 作为触发点。
 *
 * ## 现在只有两档
 *
 * 用户只要求两个档位：**60 帧**（省电，阅读完全够用）与
 * **最高帧率**（把屏幕能跑的最高档跑满，如 144Hz）。
 * 之前中间的"标准 120Hz"与"跟随系统"两档都已移除。
 */
class RefreshRateController(private val activity: Activity) {

    companion object {
        private const val TAG = "inkScrollHz"

        /** 60 帧档的目标刷新率 */
        private const val SIXTY_HZ = 60f

        /** 刷新率匹配容差（设备上报值常有 120.00001 这种浮点误差） */
        private const val HZ_EPSILON = 1.5f
    }

    private var windowAppliedHz = 0f

    /// 刷新率档位策略（由 Flutter 侧设置，见 ReaderSettings.highRefreshMode）：
    ///   sixty — 固定 60 帧（省电，阅读完全够用）
    ///   max   — 用屏幕最高档（如 144Hz 设备跑满 144Hz）
    @Volatile
    private var targetMode: String = "max"

    /** 切换档位（Dart 侧启动时 / 用户改设置时调用） */
    fun setTarget(mode: String) {
        if (mode == targetMode) return
        targetMode = mode
        windowAppliedHz = 0f // 强制重新应用
        applyWindowMode()
        applySurfaceFrameRate()
    }

    // ------------------------------------------------------------------
    // 对外入口
    // ------------------------------------------------------------------

    /** 在 onCreate / onResume 里调用：先把窗口的显示模式切过去 */
    fun applyWindowMode() {
        // 60 帧档：目标就是 60Hz，走与最高档完全相同的流程
        // （声明 60Hz 反而比"不声明"更可靠 —— 国产 ROM 对不声明的应用
        //  才可能按自己的规则降到 60Hz 以下）。
        val display = resolveDisplay() ?: run {
            Log.w(TAG, "拿不到 Display，跳过刷新率设置")
            return
        }
        val target = pickTargetHz(display)
        if (abs(target - windowAppliedHz) < HZ_EPSILON) return

        val mode = pickMode(display, target) ?: run {
            Log.w(TAG, "同分辨率下找不到 ${target}Hz 的显示模式")
            return
        }

        try {
            val attrs = activity.window.attributes
            if (attrs.preferredDisplayModeId != mode.modeId) {
                attrs.preferredDisplayModeId = mode.modeId
                attrs.preferredRefreshRate = mode.refreshRate
                activity.window.attributes = attrs
                windowAppliedHz = target
                Log.i(
                    TAG,
                    "窗口显示模式 → modeId=${mode.modeId} " +
                        "${mode.physicalWidth}x${mode.physicalHeight}@${mode.refreshRate}Hz"
                )
            } else {
                windowAppliedHz = target
            }
        } catch (e: Exception) {
            Log.w(TAG, "设置 preferredDisplayModeId 失败：${e.message}")
        }
    }

    /**
     * 在首帧渲染后 / 每次回到前台时调用。
     *
     * 此刻 Flutter 的 Surface 才真正有效，`setFrameRate` 才会生效。
     */
    fun applySurfaceFrameRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        val display = resolveDisplay() ?: return
        val target = pickTargetHz(display)

        val surfaceView = findFlutterSurfaceView() ?: run {
            Log.w(TAG, "找不到 Flutter 的 SurfaceView，跳过 setFrameRate")
            return
        }

        val surface: Surface = surfaceView.holder?.surface ?: return
        if (!surface.isValid) {
            Log.w(TAG, "Surface 尚未就绪，跳过 setFrameRate")
            return
        }

        try {
            // FIXED_SOURCE：告诉系统"我就是按这个帧率出帧，不要擅自降档"。
            // 阅读器滚动是持续动画，降档会直接表现为掉帧。
            surface.setFrameRate(target, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            Log.i(TAG, "Surface.setFrameRate → ${target}Hz（FIXED_SOURCE）")
        } catch (e: Exception) {
            Log.w(TAG, "Surface.setFrameRate 失败：${e.message}")
        }
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun resolveDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            activity.windowManager?.defaultDisplay
        }

    /**
     * 挑目标刷新率。
     *
     * max 档位：直接用屏幕最高档（144Hz 设备不再被压到 60Hz）。
     * sixty 档位：固定 60Hz（设备没有 60 档时退到最低档）。
     */
    private fun pickTargetHz(display: Display): Float {
        val rates = display.supportedModes
            .map { it.refreshRate }
            .filter { it > 0f }
            .distinct()

        if (rates.isEmpty()) return 60f
        if (targetMode == "max") return rates.maxOrNull() ?: 60f

        // sixty：优先精确的 60Hz，没有就退到不高于 60 的最大档
        rates.firstOrNull { abs(it - SIXTY_HZ) < HZ_EPSILON }?.let { return it }
        rates.filter { it <= SIXTY_HZ + HZ_EPSILON }.maxOrNull()?.let { return it }
        return rates.minOrNull() ?: 60f
    }

    /**
     * 在**与当前分辨率相同**的模式里，找刷新率等于 [target] 的那一档。
     *
     * 必须锁定分辨率：设备上同时存在 1260x2800@120 和 1080x2400@144 两种模式，
     * 如果不筛分辨率，切模式会**连带把屏幕分辨率改掉**，画面会糊。
     */
    private fun pickMode(display: Display, target: Float): Display.Mode? {
        val current = display.mode ?: return null
        val baseW = current.physicalWidth
        val baseH = current.physicalHeight

        val sameRes = display.supportedModes.filter {
            it.physicalWidth == baseW && it.physicalHeight == baseH
        }
        val candidates = sameRes.ifEmpty { display.supportedModes.toList() }

        return candidates
            .filter { abs(it.refreshRate - target) < HZ_EPSILON }
            .minByOrNull { it.modeId }
    }

    /**
     * 找 Flutter 真正用于绘制的 `SurfaceView`。
     *
     * `FlutterView` 是 `FrameLayout`，内部持有 `FlutterSurfaceView`
     * （`SurfaceView` 子类），但它**没有暴露 getter**，只能遍历子视图。
     * `FlutterImageView`（首帧前的截图面）是 `ImageView`，不会被误选。
     */
    private fun findFlutterSurfaceView(): SurfaceView? {
        val root = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
            ?: activity.window?.decorView
            ?: return null
        return searchSurfaceView(root, 0)
    }

    private fun searchSurfaceView(v: View, depth: Int): SurfaceView? {
        if (depth > 8) return null
        if (v is SurfaceView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                searchSurfaceView(v.getChildAt(i), depth + 1)?.let { return it }
            }
        }
        return null
    }
}
