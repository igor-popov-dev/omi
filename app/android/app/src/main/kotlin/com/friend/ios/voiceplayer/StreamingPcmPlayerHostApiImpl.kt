package com.friend.ios.voiceplayer

/**
 * Pigeon adapter: forwards host-API calls straight to the controller. No logic
 * lives here (the Kotlin peer of [com.friend.ios.phonemic.PhoneMicHostApiImpl]).
 */
class StreamingPcmPlayerHostApiImpl(private val controller: StreamingPcmPlayerController) : StreamingPcmPlayerHostApi {
    override fun start(sessionId: Long, callback: (Result<Unit>) -> Unit) =
        controller.start(sessionId, callback)

    override fun enqueuePcm16(bytes: ByteArray, sessionId: Long) =
        controller.enqueuePcm16(bytes, sessionId)

    override fun flush(sessionId: Long) = controller.flush(sessionId)

    override fun clear(sessionId: Long) = controller.clear(sessionId)

    override fun close(sessionId: Long, callback: (Result<Unit>) -> Unit) =
        controller.close(sessionId, callback)
}
