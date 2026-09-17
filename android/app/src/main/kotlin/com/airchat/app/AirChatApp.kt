package com.airchat.app

import android.app.Application

class AirChatApp : Application() {

    val container: AirChatContainer by lazy { AirChatContainer(this) }
}
