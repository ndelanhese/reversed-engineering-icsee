package io.github.ndelanhese.reversedicsee

import android.content.Context
import android.view.View
import android.widget.FrameLayout

/** Camera previews keep their framing as the window width changes. */
class AspectFrame(context: Context) : FrameLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = View.MeasureSpec.getSize(widthMeasureSpec)
        super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(width * 9 / 16, View.MeasureSpec.EXACTLY))
    }
}
