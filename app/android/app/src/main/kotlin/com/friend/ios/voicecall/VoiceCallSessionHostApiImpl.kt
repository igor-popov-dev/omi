package com.friend.ios.voicecall

/**
 * Pigeon glue only — no logic. All behavior, doc contracts, and threading
 * live on [VoiceCallController] (the Kotlin peer of
 * [com.friend.ios.voiceplayer.StreamingPcmPlayerHostApiImpl]).
 */
class VoiceCallSessionHostApiImpl(private val controller: VoiceCallController) : VoiceCallSessionHostApi {
    override fun start(sessionId: Long, callback: (Result<Boolean>) -> Unit) =
        controller.start(sessionId, callback)

    override fun end(sessionId: Long, callback: (Result<Unit>) -> Unit) =
        controller.end(sessionId, callback)
}
