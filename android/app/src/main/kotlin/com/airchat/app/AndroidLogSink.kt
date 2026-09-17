package com.airchat.app

import android.util.Log
import com.airchat.protocol.AirChatLogger

/** Routes protocol logs to logcat so `adb logcat -s AirChat*` is useful during device testing. */
class AndroidLogSink : AirChatLogger {
    override fun log(tag: String, message: String) {
        Log.d("AirChat/$tag", message)
    }
}
