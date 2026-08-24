import os
import re
from typing import Mapping, Optional, cast

from pydantic import BaseModel, Field

from utils.llm.clients import get_llm
from utils.llm.temporal import current_date_in_tz
import logging

logger = logging.getLogger(__name__)

Record = Mapping[str, object]


# Per-step deadline for the mentor's LLM calls (self-host, lane7).
#
# This chain runs on the live transcript path: the pusher's per-connection transcript
# task awaits it, and while it is in flight new transcript items pile into a bounded
# deque that drops the oldest. The default deadline of the claude-bridge route is 120s
# (the bridge shells out to `claude -p`), which is far too long to hold that path —
# a measured healthy run of the whole three-step chain is ~15s. 45s per step keeps a
# wide margin over the healthy case while bounding a stuck bridge.
#
# Overridable so a slow host can raise it without a redeploy.
def _step_timeout_seconds() -> float:
    raw = (os.environ.get('PROACTIVE_NOTIFICATION_STEP_TIMEOUT_SECONDS') or '').strip()
    if not raw:
        return 45.0
    try:
        return float(raw)
    except ValueError:
        logger.warning('PROACTIVE_NOTIFICATION_STEP_TIMEOUT_SECONDS=%r is not a number, using 45s', raw)
        return 45.0


# ---------------------------------------------------------------------------
# Step 1: Relevance Gate — is this conversation worth evaluating?
# ---------------------------------------------------------------------------


class RelevanceResult(BaseModel):
    """Field order is load-bearing: the reasoning is declared BEFORE the verdict.

    Structured output makes the model emit the fields in declaration order, so with the
    verdict first it has to answer before it has worked anything out — and the prompt tells
    it the default answer is false. Measured on the self-host bridge with one conversation
    where the user agrees to a meeting that collides with a known flight
    (marathon/deploy/lane7-critic-series.py, --mode gate-only):

        verdict first (was):  4/10 passed the gate, and 1/14 in an earlier series
        reasoning first:      10/10 passed

    with a control conversation carrying no collision at 0/10 in both, so this is not the
    gate merely growing looser. Scores were bimodal, never near the threshold: the same
    conversation scored 0.05 or 0.95, and rejected runs routinely spelled out the collision
    in `reasoning` and then set is_relevant=false next to it — one run said "this is a
    direct collision... a classic case worth interrupting" and scored it 0.05.

    Keep the reasoning first; reordering these fields for tidiness silently brings the coin
    flip back, and its failure mode is the mentor saying nothing, which looks exactly like
    having nothing to say.
    """

    reasoning: str = Field(
        description="What specific thing in the conversation warrants a notification. Must cite a concrete detail."
    )
    context_summary: str = Field(description="Brief summary of what user is discussing (1 sentence).")
    is_relevant: bool = Field(
        description=(
            "True ONLY if there is a specific, concrete insight the user would genuinely "
            "benefit from hearing right now. Most conversations are NOT relevant — default to false."
        )
    )
    relevance_score: float = Field(
        ge=0.0,
        le=1.0,
        description=(
            "0.90+: preventing a concrete mistake or time-sensitive opportunity right now. "
            "0.75-0.89: non-obvious connection the user would genuinely miss. "
            "0.60-0.74: somewhat useful but user might figure it out. "
            "Below 0.60: not worth interrupting."
        ),
    )


GATE_PROMPT = """You decide whether {user_name}'s current conversation contains something worth interrupting them about.

Today is {current_date}. Treat this as the present when judging whether anything is upcoming, time-sensitive, or in the future. Dates in {current_date}'s year or later are normal and current; never decide a correctly stated date is wrong or in the future based on your own assumptions about the year.

IMPORTANT: Most conversations do NOT warrant a notification. Your default answer is is_relevant=false.

{user_name} should be interrupted ONLY when you can point to a SPECIFIC thing:
- {user_name} is about to make a concrete mistake (wrong numbers, contradicting a commitment, agreeing to something bad)
- Someone said something that directly conflicts with {user_name}'s stated plans, commitments, or history
- There is a time-sensitive action {user_name} should take RIGHT NOW that they will miss otherwise
- A specific, non-obvious connection between what's being said and {user_name}'s history that changes their next move

{user_name} should NOT be interrupted for:
- General conversations that loosely relate to their work or goals
- Topics where {user_name} is already handling things correctly
- Conversations where {user_name} is not speaking — unless someone said something critical that demands immediate action
- Anything where you need to stretch to justify relevance
- Opportunities to remind {user_name} about their goals (they already know their goals)
- Topics similar to RECENT NOTIFICATIONS below

== {user_name}'S FACTS ==
{user_facts}

== {user_name}'S GOALS ==
{goals_text}

== {user_name}'S RECENT CONVERSATIONS ==
{past_conversations}

== CURRENT CONVERSATION ==
{current_conversation}

== RECENT NOTIFICATIONS (do not flag similar topics) ==
{recent_notifications}

Before you answer, run this check explicitly and mention its outcome in `reasoning`:
read {user_name}'S FACTS, {user_name}'S GOALS and {user_name}'S RECENT CONVERSATIONS above, and
compare them against anything {user_name} is agreeing to, scheduling, or committing to in the
CURRENT CONVERSATION. A commitment that collides with a known fact, goal, or something
{user_name} already said in a recent conversation (same day, overlapping time, incompatible
place, contradicted decision) is exactly the case worth interrupting — {user_name} usually does
not notice these in the moment. A collision needs two KNOWN things that cannot both hold;
a detail nobody has looked up yet is not one. If there is no such collision, say so — that
alone does not settle the answer, the criteria above still do — and otherwise stay with
is_relevant=false.{language_instruction}"""


# ---------------------------------------------------------------------------
# Step 2: Generate — produce the actual notification text
# ---------------------------------------------------------------------------


class NotificationDraft(BaseModel):
    """Unlike :class:`RelevanceResult` and :class:`ValidationResult`, the field order here
    is NOT load-bearing — measured, not assumed.

    Both siblings above carry loud "keep the reasoning first" docstrings, so reordering this
    one to match looks like tidying up. It was tried on the same harness
    (marathon/deploy/lane7-critic-series.py, --mode draft-only, 10 runs per input, a
    conversation colliding with a known flight against a control conversation with no
    collision at all):

        as-is (this order):  collision 10/10 over the threshold, control 0/10
                             confidence 0.95-0.97 against 0.62-0.65
        reasoning first:     collision 10/10,                    control 1/10
                             confidence 0.95-0.97 against 0.62-0.78

    Nothing to gain, and the control drifts up. The reason the siblings suffer and this one
    does not: their output is a binary verdict under a prompt whose stated default is "no",
    so a verdict written before the reasoning inherits that default. This stage has no
    default to inherit, its first field is the notification text itself — which is the
    reasoning, in effect — and `confidence` is written after it either way.
    """

    notification_text: str = Field(
        description="The notification. Max 100 chars. Specific and actionable. Like a text from a sharp friend."
    )
    reasoning: str = Field(
        description=(
            "Why this is worth sending. MUST cite specific names, numbers, dates, or quotes "
            "from the conversation or user history."
        )
    )
    confidence: float = Field(
        ge=0.0,
        le=1.0,
        description=(
            "0.90+: preventing a clear mistake or critical time-sensitive action. "
            "0.75-0.89: genuinely non-obvious connection the user would miss. "
            "0.60-0.74: useful but user might figure it out. "
            "Below 0.60: do not send."
        ),
    )
    category: str = Field(description="One of: productivity, mistake_prevention, goal_connection, dot_connecting")


GENERATE_PROMPT = """{user_name}'s conversation was flagged as containing something worth a notification.

Today is {current_date}. Treat this as the present; a correctly stated date in {current_date}'s year or later is normal, not an error or something to warn the user about.

The reason it was flagged: {gate_reasoning}

Generate ONE specific, actionable notification.

Rules:
- State WHAT happened and WHAT {user_name} should do — be concrete
- Reference specific names, numbers, or things actually said in the conversation
- Write it like a sharp friend texting, not a corporate advisor
- NEVER start with: Confirm, Ensure, Clarify, Consider, Prioritize, Remember, Review, Align, Make sure, Don't forget
- Under 100 characters
- The notification must contain information {user_name} does NOT already have, or a connection they can't see
- Every concrete figure you state — a duration, price, deadline, count, date — must already appear
  in the CURRENT CONVERSATION, FACTS, GOALS or PAST CONVERSATIONS below. You are looking at one
  person's day, not at the world: you do not know how long an office takes, what something costs,
  or how far away a place is unless it is written below. When the useful point is that such a
  figure is missing, say it is unknown and worth checking — never supply a plausible one{language_instruction}

== {user_name}'S FACTS ==
{user_facts}

== {user_name}'S GOALS ==
{goals_text}

== RELEVANT PAST CONVERSATIONS ==
{past_conversations}

== CURRENT CONVERSATION ==
{current_conversation}

== RECENT NOTIFICATIONS (do not repeat) ==
{recent_notifications}

== FREQUENCY ==
{frequency_guidance}"""


# ---------------------------------------------------------------------------
# Step 3: Critic — would a human actually want this notification?
# ---------------------------------------------------------------------------


class ValidationResult(BaseModel):
    """Reasoning before verdict, for the same measured reason as :class:`RelevanceResult`.

    Same harness, same fixed inputs — a strong draft naming a real collision, and an empty
    reminder as the control that must stay rejected:

        verdict first:    strong draft 7/10 approved, control 0/10
        reasoning first:  strong draft 10/10 approved, control 0/10

    The critic's prompt is built around "most notifications should be REJECTED", so a
    verdict written before the reasoning inherits that default rather than the argument.
    """

    reasoning: str = Field(description="Why this should or should not be sent to the user's phone.")
    approved: bool = Field(
        description="True ONLY if you would genuinely want to receive this notification yourself. Most should be rejected."
    )


CRITIC_PROMPT = """You are the last gate before this notification hits {user_name}'s phone. Your job is to BLOCK bad notifications. Most notifications should be REJECTED.

Today is {current_date}. REJECT any notification that claims a correctly stated date is in the future, or that the user's clock, calendar, or system date is wrong, when that is based only on an assumption about what year it is. Dates in {current_date}'s year or later are normal.

NOTIFICATION: "{notification_text}"
REASONING: "{draft_reasoning}"

THE CONVERSATION IT'S BASED ON:
{current_conversation}

{user_name}'S GOALS:
{goals_text}

{user_name}'S FACTS (what is known about them OUTSIDE this conversation):
{user_facts}

{user_name}'S RECENT CONVERSATIONS (what they said BEFORE this one):
{past_conversations}

Imagine you are {user_name}. You're in the middle of a conversation. Your phone buzzes. You look down and see this notification. Do you think:
A) "Oh shit, glad I saw this — this changes what I do next" → APPROVE
B) "I already know this / this is obvious / this is annoying / so what?" → REJECT

REJECT if ANY of these are true:
- The notification tells {user_name} something they clearly already know from the conversation
- The notification is a reminder about goals without providing new information
- The advice could apply to literally anyone in any conversation
- The notification uses vague corporate language (align, prioritize, leverage, ensure, optimize, reassess)
- The notification starts with a goal name (e.g. "30-video goal:", "Meet 12 people goal:")
- Removing this notification from {user_name}'s day would change absolutely nothing
- The "specific reference" in the reasoning is actually a stretch or very generic{language_instruction}

APPROVE only if ALL of these are true:
- The notification contains specific information {user_name} genuinely does not have right now
- A smart friend would say this exact thing in person and {user_name} would thank them
- NOT seeing this notification could lead to a missed opportunity or avoidable mistake"""


# Accept only clean BCP-47-style language/locale tokens (e.g. ja, pt-BR, zh-TW). The language comes
# from a user-controlled preference and is interpolated into the prompts, so reject anything else
# (newlines, punctuation, extra text) to prevent prompt injection.
_BCP47_LANGUAGE_RE = re.compile(r'[A-Za-z]{2,8}(-[A-Za-z0-9]{2,8})*')


def _language_instruction(output_language: str, *, for_critic: bool = False, for_gate: bool = False) -> str:
    """Instruction telling the model to write (or, for the critic, reject if not written in) the
    user's language (#5214).

    Returns "" for English, an unset language, or any value that is not a clean BCP-47 token, so the
    model defaults to English and a user-controlled preference cannot inject prompt text. English
    family codes (en, en-US, ...) intentionally produce no instruction.

    ``for_gate`` is a third wording because the gate writes no notification: it answers a verdict,
    and its ``reasoning`` is handed to the generate step as ``gate_reasoning``. Left without an
    instruction it answers in the prompt's language whenever the conversation gives it little
    Russian to hold on to — measured on the live path, 6 of 9 gate answers on the user's own
    conversations came back in English — and that English reasoning is then what the generate step
    reads before writing the text the user sees. Telling the gate to "write the notification in the
    user's language" would be an instruction about an output it does not have, so the wording names
    the two fields it does produce and says outright that the verdict itself must not change.
    """
    lang = (output_language or 'en').strip()
    if not lang or lang.lower().startswith('en') or not _BCP47_LANGUAGE_RE.fullmatch(lang):
        return ""
    if for_critic:
        return f"\n- The notification is written in a language other than the user's (expected code: {lang})"
    if for_gate:
        return (
            f"\n\nWrite `reasoning` and `context_summary` entirely in the user's language "
            f"(language/locale code: {lang}). This does not change WHAT you decide — only the "
            f"language you write the decision in.\n"
        )
    return f"\n- Write the notification entirely in the user's language (language/locale code: {lang})"


# ---------------------------------------------------------------------------
# Legacy models (kept for eval tests backward compatibility)
# ---------------------------------------------------------------------------


class ProactiveAdvice(BaseModel):
    notification_text: str = Field(
        description="The advice. Max 100 chars. Start with the actionable part. No filler words."
    )
    reasoning: str = Field(
        description=(
            "Why this is worth interrupting. MUST cite a specific date, quote, or detail "
            "from the user's facts, goals, or past conversations. "
            "If you can only say 'user mentioned X' without a concrete reference, set has_advice=false."
        )
    )
    confidence: float = Field(
        ge=0.0,
        le=1.0,
        description=(
            "0.90+: preventing a concrete mistake or critical non-obvious connection. "
            "0.75-0.89: specific dot-connecting across conversations the user would miss. "
            "0.60-0.74: useful but user might figure it out. "
            "Below 0.60: do not send."
        ),
    )
    category: str = Field(description="One of: productivity, mistake_prevention, goal_connection, dot_connecting")


class ProactiveNotificationResult(BaseModel):
    has_advice: bool = Field(
        description=(
            "True ONLY when advice is SPECIFIC to the conversation AND the user likely "
            "would NOT figure it out themselves. False in all other cases."
        )
    )
    advice: Optional[ProactiveAdvice] = Field(
        default=None, description="The notification to send. Required when has_advice is true."
    )
    context_summary: str = Field(description="Brief summary of what user is discussing (1 sentence). Always provided.")
    current_activity: str = Field(default="", description="What the user is doing or deciding right now.")


# ---------------------------------------------------------------------------
# Thresholds & frequency config
# ---------------------------------------------------------------------------

FREQUENCY_TO_BASE_THRESHOLD = {
    0: None,
    1: 0.92,
    2: 0.85,
    3: 0.78,
    4: 0.70,
    5: 0.60,
}

FREQUENCY_GUIDANCE = {
    1: "Ultra selective. Only prevent clear mistakes or truly critical insights. 1-3 per day max.",
    2: "Very selective. Only non-obvious insights tied to specific goals or history. 3-5 per day.",
    3: "Balanced. Only when you have a specific, actionable insight the user would miss. 5-8 per day.",
    4: "Proactive. Share specific insights connecting this conversation to goals/history. 6-9 per day.",
    5: "Very proactive. Share insights when you spot non-obvious connections. Up to 9 per day.",
}


def _resolve_daily_cap(default: int = 9, minimum: int = 1, maximum: int = 1000) -> int:
    """Read the daily-cap override, clamped to a sane range.

    A non-integer or unset value falls back to the default, and the result is
    bounded so a typo cannot silently disable proactive notifications (0/negative)
    or remove throttling entirely (an accidental huge value)."""
    raw = os.getenv('MAX_DAILY_NOTIFICATIONS')
    if raw is None:
        return default
    try:
        return max(minimum, min(int(raw), maximum))
    except (TypeError, ValueError):
        return default


# Hard ceiling on proactive notifications per user per day, across every source
# (mentor + third-party proactive apps). Defaults to 9 to keep the user under the
# "less than 10 daily notifs" target in #4859; override with the env var to tune
# without a code change.
MAX_DAILY_NOTIFICATIONS = _resolve_daily_cap()


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------


def _str_value(value: object, default: str = "") -> str:
    if isinstance(value, str):
        return value
    return default


def _format_goals(goals: list[Record]) -> str:
    if not goals:
        return "No active goals set."
    lines: list[str] = []
    for g in goals:
        title = _str_value(g.get('title'), _str_value(g.get('description'), 'Unnamed goal'))
        description = _str_value(g.get('description'))
        if description and description != title:
            lines.append(f"- {title}: {description}")
        else:
            lines.append(f"- {title}")
    return "\n".join(lines)


def _format_current_conversation(messages: list[Record], user_name: str) -> str:
    if not messages:
        return "No conversation in progress."
    lines: list[str] = []
    for msg in messages:
        speaker = user_name if msg.get('is_user') else "Other"
        lines.append(f"[{speaker}]: {_str_value(msg.get('text'))}")
    return "\n".join(lines)


def _format_recent_notifications(notifications: list[Record]) -> str:
    if not notifications:
        return "No recent notifications sent."
    lines: list[str] = []
    for n in notifications:
        created = _str_value(n.get('created_at'), 'unknown time')
        text = _str_value(n.get('text'))
        lines.append(f"[{created}]: {text}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Step 1: Gate
# ---------------------------------------------------------------------------


def evaluate_relevance(
    user_name: str,
    user_facts: str,
    goals: list[Record],
    current_messages: list[Record],
    recent_notifications: list[Record],
    current_date: Optional[str] = None,
    past_conversations_str: str = '',
    output_language: str = 'en',
) -> RelevanceResult:
    """Cheap first pass: is this conversation worth generating a notification for?

    ``past_conversations_str`` is the caller's cheap recent-by-time context. The gate is the only
    step that decides whether anything happens at all, so a conflict it cannot see is a
    notification that can never be sent — and the collision this chain is most valuable for
    ("you just agreed to Thursday afternoon; yesterday you said you fly out Thursday at two")
    lives in a past conversation, not in the last ten lines. Semantic retrieval stays after the
    gate: that one needs an embedding provider, and this step must stay cheap.
    """
    goals_text = _format_goals(goals)
    current_conversation = _format_current_conversation(current_messages, user_name)
    notifications_text = _format_recent_notifications(recent_notifications)

    prompt = GATE_PROMPT.format(
        user_name=user_name,
        user_facts=user_facts,
        goals_text=goals_text,
        past_conversations=past_conversations_str or 'None available.',
        current_conversation=current_conversation,
        recent_notifications=notifications_text,
        current_date=current_date or current_date_in_tz(None),
        language_instruction=_language_instruction(output_language, for_gate=True),
    )

    with_parser = get_llm('proactive_notification', request_timeout=_step_timeout_seconds()).with_structured_output(
        RelevanceResult
    )
    result = cast(RelevanceResult, with_parser.invoke(prompt))
    return result


# ---------------------------------------------------------------------------
# Step 2: Generate
# ---------------------------------------------------------------------------


def generate_notification(
    user_name: str,
    user_facts: str,
    goals: list[Record],
    past_conversations_str: str,
    current_messages: list[Record],
    recent_notifications: list[Record],
    frequency: int,
    gate_reasoning: str,
    output_language: str = 'en',
    current_date: Optional[str] = None,
) -> NotificationDraft:
    """Generate the actual notification text, only called when gate passes."""
    goals_text = _format_goals(goals)
    current_conversation = _format_current_conversation(current_messages, user_name)
    notifications_text = _format_recent_notifications(recent_notifications)
    guidance = FREQUENCY_GUIDANCE.get(frequency, FREQUENCY_GUIDANCE[3])

    prompt = GENERATE_PROMPT.format(
        user_name=user_name,
        user_facts=user_facts,
        goals_text=goals_text,
        past_conversations=(
            past_conversations_str if past_conversations_str else "No relevant past conversations found."
        ),
        current_conversation=current_conversation,
        recent_notifications=notifications_text,
        frequency_guidance=guidance,
        gate_reasoning=gate_reasoning,
        language_instruction=_language_instruction(output_language),
        current_date=current_date or current_date_in_tz(None),
    )

    with_parser = get_llm('proactive_notification', request_timeout=_step_timeout_seconds()).with_structured_output(
        NotificationDraft
    )
    result = cast(NotificationDraft, with_parser.invoke(prompt))
    return result


# ---------------------------------------------------------------------------
# Step 3: Critic
# ---------------------------------------------------------------------------


def validate_notification(
    user_name: str,
    notification_text: str,
    draft_reasoning: str,
    current_messages: list[Record],
    goals: list[Record],
    output_language: str = 'en',
    current_date: Optional[str] = None,
    user_facts: str = '',
    past_conversations_str: str = '',
) -> ValidationResult:
    """Final human-perspective check: would you actually want this on your phone?

    The critic sees the user's facts because without them it cannot tell a real
    cross-source collision from a rehash of the conversation. The gate and the
    generate step are both given the facts; only the critic was not, and every
    notification whose value comes from outside the conversation — the class this
    whole chain exists for — reads to it as "the user just said this themselves".

    Measured on the self-host bridge, 10 runs per cell, one fixed conversation where
    the user agrees to a meeting that collides with a known flight
    (marathon/deploy/lane7-critic-series.py):

        without facts:      strong draft 0/10 approved, empty reminder 0/10
        with facts (this):  strong draft 7/10 approved, empty reminder 0/10

    Without the facts the critic did not merely reject too much — it could not
    separate the two inputs at all, rejecting both with the same sentence. The
    facts alone restore the separation.

    The three remaining rejections all argue that the user should have noticed the
    collision himself. An extra "a collision is not a rehash" instruction removes
    exactly that argument and was measured in the same harness — it pulled the
    strong draft to 10/10 but also the empty reminder to 6/10, i.e. it buys
    approvals by destroying the control, so it is deliberately not here.

    The past conversations are here for the same reason, and the facts alone do not
    cover it: the gate reads the last conversations too, so it can pass on a collision
    whose other half was simply said yesterday and never distilled into a fact. Measured
    with the same harness, 8 runs per cell, facts deliberately holding no flight so the
    only source is a past conversation (`--mode past`):

        without past conversations: grounded collision 0/8 approved
        with them (this):           grounded collision 8/8 approved
        controls, with them:        invented collision 0/8, empty reminder 0/8

    All eight rejections in the first cell say the same thing — "the conversation says
    nothing about a flight to Petersburg" — which is true of the transcript and false of
    the user's week. The controls are what make the fix a fix rather than a licence to
    believe the draft's reasoning: a notification citing a report deadline nobody ever
    mentioned is still rejected 8/8, and rejected for that reason."""
    current_conversation = _format_current_conversation(current_messages, user_name)
    goals_text = _format_goals(goals)

    prompt = CRITIC_PROMPT.format(
        user_name=user_name,
        notification_text=notification_text,
        draft_reasoning=draft_reasoning,
        current_conversation=current_conversation,
        goals_text=goals_text,
        user_facts=user_facts or 'None available.',
        past_conversations=past_conversations_str or 'None available.',
        language_instruction=_language_instruction(output_language, for_critic=True),
        current_date=current_date or current_date_in_tz(None),
    )

    with_parser = get_llm('proactive_notification', request_timeout=_step_timeout_seconds()).with_structured_output(
        ValidationResult
    )
    result = cast(ValidationResult, with_parser.invoke(prompt))
    return result


# ---------------------------------------------------------------------------
# Legacy single-call (kept for eval tests)
# ---------------------------------------------------------------------------

PROACTIVE_PROMPT_TEMPLATE = """You analyze {user_name}'s live conversations to find ONE specific, high-value insight they would NOT figure out on their own.

Today is {current_date}. Treat this as the present when reasoning about deadlines, "tomorrow", or whether something is upcoming. Never flag a correctly stated date as wrong or in the future based on an assumption about the year.

CORE QUESTION: Is {user_name} about to make a mistake, missing a non-obvious connection to their goals/history, or forgetting a commitment?

SET has_advice=true ONLY when you can answer YES to BOTH:
1. The advice is SPECIFIC to what's being discussed (not generic wisdom)
2. {user_name} likely does NOT already know this (non-obvious)

SET has_advice=false when:
- You'd be stating something obvious ({user_name} can figure it out themselves)
- The advice is generic and not tied to the specific conversation content
- The advice is similar to something in RECENT NOTIFICATIONS (check below)
- You sent a notification on the same topic in the last 24 hours (check RECENT NOTIFICATIONS timestamps)
- You're reaching — if you have to stretch to find advice, there isn't any

WHAT QUALIFIES (high bar):
- {user_name} is about to make a decision that contradicts a specific goal they set
- {user_name} mentioned person X two weeks ago in context Y, and that's directly relevant now
- {user_name} committed to doing X but is now doing the opposite
- A specific fact from {user_name}'s history directly applies to the current conversation
- {user_name} is repeating a pattern you've seen before that led to a bad outcome

WHAT DOES NOT QUALIFY (instant has_advice=false):
- "Take a break" / "Stay hydrated" / "Practice mindfulness" / "Pause and reflect" (wellness)
- "Stay focused" / "You've got this" / "Believe in yourself" (motivational platitudes)
- "It sounds like you're frustrated" / "Let's take a moment" (therapist-speak)
- "You should think about..." / "Consider..." / "You might want to..." (vague suggestions)
- "Confirm [thing]" / "Ensure [thing]" / "Clarify [thing]" — restating awareness is NOT advice. {user_name} already knows what they're working on. Only qualify if you're adding a SPECIFIC fact they don't have.
- Restating what {user_name} just said in different words
- Generic productivity advice that applies to anyone
- Anything about emotions, stress, frustration, or feelings
- Advice that could be given without knowing {user_name}'s specific history/goals

== {user_name}'S FACTS ==
{user_facts}

== {user_name}'S GOALS ==
{goals_text}

== RELEVANT PAST CONVERSATIONS ==
{past_conversations}

== CURRENT CONVERSATION ==
{current_conversation}

== RECENT NOTIFICATIONS (do not repeat or send semantically similar) ==
{recent_notifications}

== FREQUENCY ==
{frequency_guidance}

FORMAT: Keep notification_text under 100 characters.
- NEVER start with a goal name ("30-video goal:", "12-people goal:")
- NEVER say "your X goal" in the notification
- NEVER start with: Confirm, Ensure, Clarify, Consider, Prioritize, Remember, Review, Align, Reassess
- Lead with the action or the conflict, not the goal
- Write like you're texting a friend, not writing a corporate memo
- GOOD: "You just paused videos but your deadline means you'll fall behind by 6"
- GOOD: "Ask [Name] to grab coffee — strong fit and you're only at 4/12"
- GOOD: "Call Mike about the deal — he mentioned a deadline Friday"
- BAD: "30-video goal: line up a backup editor today"
- BAD: "Consider aligning your NYC plans with your growth strategy"
- BAD: "Your messages show frustration and maybe anger. Let's take a moment."

REASONING must cite a SPECIFIC date, quote, or detail from {user_name}'s facts, goals, or past conversations. Example: "On Feb 12, {user_name} told Mike he'd finish by Friday — that's tomorrow and he hasn't started." If your reasoning only says "{user_name} mentioned X" without a concrete reference, set has_advice=false."""


def evaluate_proactive_notification(
    user_name: str,
    user_facts: str,
    goals: list[Record],
    past_conversations_str: str,
    current_messages: list[Record],
    recent_notifications: list[Record],
    frequency: int,
    current_date: Optional[str] = None,
) -> ProactiveNotificationResult:
    """Legacy single-call evaluation. Kept for eval tests."""
    goals_text = _format_goals(goals)
    current_conversation = _format_current_conversation(current_messages, user_name)
    notifications_text = _format_recent_notifications(recent_notifications)
    guidance = FREQUENCY_GUIDANCE.get(frequency, FREQUENCY_GUIDANCE[3])

    prompt = PROACTIVE_PROMPT_TEMPLATE.format(
        user_name=user_name,
        user_facts=user_facts,
        goals_text=goals_text,
        past_conversations=(
            past_conversations_str if past_conversations_str else "No relevant past conversations found."
        ),
        current_conversation=current_conversation,
        recent_notifications=notifications_text,
        frequency_guidance=guidance,
        current_date=current_date or current_date_in_tz(None),
    )

    with_parser = get_llm('proactive_notification', request_timeout=_step_timeout_seconds()).with_structured_output(
        ProactiveNotificationResult
    )
    result = cast(ProactiveNotificationResult, with_parser.invoke(prompt))
    return result
