"""
Mentor notification system for providing real-time mentorship during conversations.

This module buffers conversation segments and determines when enough context
has accumulated to evaluate a proactive notification.
"""

import time
import threading
import logging
from typing import List, Dict, Any

from database.notifications import get_mentor_notification_frequency

logger = logging.getLogger(__name__)

# Maximum messages to keep in buffer (prevents unbounded growth in long conversations)
MAX_BUFFER_MESSAGES = 50

# Minimum NEW segments needed since last evaluation before triggering another
MIN_NEW_SEGMENTS_FOR_ANALYSIS = 10


class MessageBuffer:
    """Manages conversation buffers for mentor notification analysis."""

    def __init__(self):
        self.buffers: Dict[str, Dict[str, Any]] = {}
        self.lock = threading.Lock()
        self.cleanup_interval = 600  # 10 minutes
        self.last_cleanup = time.time()
        self.silence_threshold = 120  # 2 minutes silence threshold
        self.min_words_after_silence = 5  # minimum words needed after silence
        # How stale a finished conversation may be and still be worth one last look.
        #
        # Silence is noticed lazily — nothing runs on a timer, so `get_buffer` only learns the
        # conversation ended when the *next* segment arrives. Usually that is minutes later and
        # the advice is still about something the user is living through. It can also be hours,
        # and a mentor that interrupts a fresh conversation to comment on this morning's is worse
        # than one that says nothing: this chain exists to catch "you just agreed to Thursday",
        # which stops being worth a push long before it stops being true.
        self.max_final_flush_silence = 1800  # 30 minutes

    def get_buffer(self, session_id: str) -> Dict[str, Any]:
        """Get or create buffer for a session."""
        current_time = time.time()

        # Cleanup old sessions periodically
        if current_time - self.last_cleanup > self.cleanup_interval:
            self.cleanup_old_sessions()

        with self.lock:
            if session_id not in self.buffers:
                self.buffers[session_id] = {
                    'messages': [],
                    'last_analysis_time': time.time(),
                    'last_activity': current_time,
                    'words_after_silence': 0,
                    'silence_detected': False,
                    'messages_at_last_analysis': 0,
                }
            else:
                # Check for silence period
                time_since_activity = current_time - self.buffers[session_id]['last_activity']
                if time_since_activity > self.silence_threshold:
                    # The conversation just ended, and this is the only moment it is ever
                    # complete. Hand it back for one last evaluation before dropping it.
                    #
                    # Analysis is triggered by a counter — MIN_NEW_SEGMENTS_FOR_ANALYSIS new
                    # segments and nothing else — so the last, incomplete group of segments in
                    # every conversation was never looked at. Measured on the live account
                    # (lane7 tick 33): 62 triggers, every one of them at a multiple of ten
                    # (10, 20, 30, 40, 50), not a single one on a tail.
                    #
                    # That is the wrong material to throw away. The gate scores by collision
                    # with what is already known, and the collision assembles as the
                    # conversation completes — same conversation, same corpus, five runs per
                    # buffer size: 4 of 10 segments scored 0.12-0.25, 7 of 10 scored 0.30-0.45,
                    # and only the whole 10 reached 0.86 and crossed the threshold. The spread
                    # at the shorter sizes is tight, so this is not the score merely growing
                    # noisier — the shorter buffers cannot reach the answer at all.
                    #
                    # Only when something in it has never been evaluated: a buffer that was
                    # analysed on its very last segment would otherwise be re-sent verbatim,
                    # paying an LLM call to ask a question already answered.
                    stale = time_since_activity > self.max_final_flush_silence
                    pending = self.buffers[session_id]['messages']
                    unseen = len(pending) - self.buffers[session_id].get('messages_at_last_analysis', 0)
                    if pending and unseen > 0 and not stale:
                        self.buffers[session_id]['final_pending'] = pending
                    self.buffers[session_id]['silence_detected'] = True
                    self.buffers[session_id]['words_after_silence'] = 0
                    self.buffers[session_id]['messages'] = []  # Clear old messages after silence
                    self.buffers[session_id]['messages_at_last_analysis'] = 0

                self.buffers[session_id]['last_activity'] = current_time

        return self.buffers[session_id]

    def cleanup_old_sessions(self):
        """Remove sessions older than 1 hour."""
        current_time = time.time()
        with self.lock:
            expired_sessions = [
                session_id
                for session_id, data in self.buffers.items()
                if current_time - data['last_activity'] > 3600  # Remove sessions older than 1 hour
            ]
            for session_id in expired_sessions:
                del self.buffers[session_id]
            self.last_cleanup = current_time
            if expired_sessions:
                logger.warning(f"Cleaned up {len(expired_sessions)} expired mentor notification sessions")


# Global message buffer
message_buffer = MessageBuffer()


def process_mentor_notification(uid: str, segments: List[Dict[str, Any]]) -> List[Dict[str, Any]] | None:
    """
    Process segments for mentor notification.

    Buffers incoming segments and returns the full accumulated conversation
    when enough new context has been gathered since last evaluation.
    Buffer accumulates across evaluations (not cleared) so the LLM sees
    the full conversation. Only clears on silence (2 min gap).

    Args:
        uid: User ID
        segments: List of conversation segments

    Returns:
        List of conversation message dicts if ready for evaluation, None otherwise.
        Each message dict has 'text', 'timestamp', and 'is_user' keys.
    """
    # Check if mentor notifications are enabled for this user
    frequency = get_mentor_notification_frequency(uid)
    if frequency == 0:
        return None

    current_time = time.time()
    buffer_data = message_buffer.get_buffer(uid)

    # Process new messages
    for segment in segments:
        if not segment.get('text'):
            continue

        text = segment['text'].strip()
        if text:
            # `start` is an offset into the recording, so the first segment of every
            # conversation is 0.0 — falsy but perfectly valid. `or current_time` replaced
            # it with wall-clock time, which sorted the opening line last (and broke the
            # 2-second coalescing below). Only a genuinely absent start should fall back.
            start_offset = segment.get('start')
            timestamp = current_time if start_offset is None else start_offset
            is_user = segment.get('is_user', False)

            # Count words after silence
            if buffer_data['silence_detected']:
                words_in_segment = len(text.split())
                buffer_data['words_after_silence'] += words_in_segment

                # If we have enough words, start fresh conversation
                if buffer_data['words_after_silence'] >= message_buffer.min_words_after_silence:
                    buffer_data['silence_detected'] = False
                    buffer_data['last_analysis_time'] = current_time  # Reset analysis timer
                    logger.info(f"Silence period ended for user {uid}, starting fresh conversation")

            can_append = (
                buffer_data['messages']
                and abs(buffer_data['messages'][-1]['timestamp'] - timestamp) < 2.0
                and buffer_data['messages'][-1].get('is_user') == is_user
            )

            if can_append:
                buffer_data['messages'][-1]['text'] += ' ' + text
            else:
                buffer_data['messages'].append({'text': text, 'timestamp': timestamp, 'is_user': is_user})

    # Trim buffer if it exceeds max size (keep most recent messages)
    if len(buffer_data['messages']) > MAX_BUFFER_MESSAGES:
        excess = len(buffer_data['messages']) - MAX_BUFFER_MESSAGES
        buffer_data['messages'] = buffer_data['messages'][excess:]
        buffer_data['messages_at_last_analysis'] = max(0, buffer_data['messages_at_last_analysis'] - excess)

    # A conversation that ended during the gap takes priority over the one starting now:
    # it is complete, and this is the only chance it gets (see get_buffer). The segments that
    # arrived with this call have already been folded into the fresh buffer above, so nothing
    # is lost by returning the old one here — they are one or two lines and will be evaluated
    # with the rest of their own conversation.
    final_pending = buffer_data.pop('final_pending', None)
    if final_pending:
        sorted_final = sorted(final_pending, key=lambda x: x['timestamp'])
        logger.info(f"Mentor notification final flush for user {uid} (total_messages={len(sorted_final)})")
        return sorted_final

    # Check if enough NEW messages since last evaluation
    new_message_count = len(buffer_data['messages']) - buffer_data.get('messages_at_last_analysis', 0)

    if new_message_count >= MIN_NEW_SEGMENTS_FOR_ANALYSIS and not buffer_data['silence_detected']:
        # Return ALL accumulated messages (not just new ones) for full context
        sorted_messages = sorted(buffer_data['messages'], key=lambda x: x['timestamp'])

        buffer_data['last_analysis_time'] = current_time
        buffer_data['messages_at_last_analysis'] = len(buffer_data['messages'])

        logger.info(
            f"Mentor notification ready for user {uid} "
            f"(total_messages={len(sorted_messages)}, new={new_message_count})"
        )
        return sorted_messages

    return None
