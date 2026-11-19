package com.relayphone.voip.runtime

import com.relayphone.voip.CallID
import com.relayphone.voip.Input
import com.relayphone.voip.RemovalCompletion
import com.relayphone.voip.State
import java.util.Collections
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow

/**
 * Position in one runtime timeline. Sequences start at zero and fit losslessly in JavaScript.
 * These cursors track reducer revisions. A transport that filters them or expands a revision
 * into multiple wire records assigns cursors on its own timeline.
 */
public data class RuntimeCursor(public val epoch: String, public val sequence: Long)

/** Latest domain state and the cursor covering it and all completed observations. */
public data class RuntimeSnapshot(public val cursor: RuntimeCursor, public val state: State)

/** An authoritative state read, a recovery signal, or a frame from the runtime journal. */
public sealed interface RuntimeObservation {
    public data class Snapshot(public val snapshot: RuntimeSnapshot) : RuntimeObservation
    public data object ResyncRequired : RuntimeObservation
}

public sealed interface RuntimeFrame : RuntimeObservation {
    public val cursor: RuntimeCursor

    /**
     * Reducer state after an input. A call in [completing] may also leave retention in this
     * revision. Transports projecting call removals can wait for its [TerminalCompleted] frame.
     */
    public data class StateRevision(
        override val cursor: RuntimeCursor, public val state: State, public val input: Input?,
        public val completing: Set<CallID>,
    ) : RuntimeFrame

    /** A transient runtime event. The frame cursor identifies its position in the journal. */
    public data class Event(override val cursor: RuntimeCursor, public val event: RuntimeEvent) : RuntimeFrame

    /** Completion of a single native removal attempt, independent of other adapter work. */
    public data class Cleanup(
        override val cursor: RuntimeCursor, public val completion: RemovalCompletion,
    ) : RuntimeFrame

    /** An ended call's last outstanding work finished. */
    public data class TerminalCompleted(
        override val cursor: RuntimeCursor, public val event: RuntimeEvent.TerminalCompleted,
    ) : RuntimeFrame
}

internal class RuntimeJournal(initial: State, private val capacity: Int) {
    init { require(capacity > 0) }

    private var latest = RuntimeSnapshot(RuntimeCursor(newEpoch(), 0), initial)
    private val advanced = MutableStateFlow(latest.cursor)
    private val frames = arrayOfNulls<RuntimeFrame>(capacity)

    @Synchronized
    fun snapshot(): RuntimeSnapshot = latest

    fun publish(
        state: State, input: Input?, cleanup: RemovalCompletion?, events: List<RuntimeEvent>,
        project: (RuntimeFrame) -> Unit,
    ) {
        val committed = synchronized(this) {
            val batchSize = 1L + events.size + if (cleanup == null) 0 else 1
            var cursor = latest.cursor
            if (cursor.sequence > MAX_SEQUENCE - batchSize) {
                frames.fill(null)
                cursor = RuntimeCursor(newEpoch(), 0)
            }
            fun append(frame: (RuntimeCursor) -> RuntimeFrame): RuntimeFrame {
                cursor = cursor.copy(sequence = cursor.sequence + 1)
                return frame(cursor).also { frames[slot(cursor.sequence)] = it }
            }

            val completing = Collections.unmodifiableSet(
                events.filterIsInstance<RuntimeEvent.TerminalCompleted>().mapTo(mutableSetOf()) { it.callID },
            )
            val batch = buildList {
                add(append { RuntimeFrame.StateRevision(it, state, input, completing) })
                if (cleanup != null) add(append { RuntimeFrame.Cleanup(it, cleanup) })
                for (event in events) {
                    add(append {
                        when (event) {
                            is RuntimeEvent.TerminalCompleted -> RuntimeFrame.TerminalCompleted(it, event)
                            else -> RuntimeFrame.Event(it, event)
                        }
                    })
                }
            }
            latest = RuntimeSnapshot(cursor, state)
            batch
        }
        committed.forEach(project)
        advanced.value = committed.last().cursor
    }

    fun observe(after: RuntimeCursor?): Flow<RuntimeObservation> = flow {
        var cursor = after ?: snapshot().also { emit(RuntimeObservation.Snapshot(it)) }.cursor
        while (true) {
            when (val next = readAfter(cursor)) {
                is RuntimeFrame -> {
                    emit(next)
                    cursor = next.cursor
                }
                RuntimeObservation.ResyncRequired -> {
                    emit(RuntimeObservation.ResyncRequired)
                    // A collector can suspend on the recovery signal. Read again on resume.
                    val fresh = snapshot()
                    emit(RuntimeObservation.Snapshot(fresh))
                    cursor = fresh.cursor
                }
                null -> advanced.first { snapshot().cursor != cursor }
                is RuntimeObservation.Snapshot -> error("Snapshots are emitted by the collector")
            }
        }
    }

    @Synchronized
    private fun readAfter(cursor: RuntimeCursor): RuntimeObservation? {
        val head = latest.cursor
        if (cursor.epoch != head.epoch || cursor.sequence !in maxOf(0, head.sequence - capacity)..head.sequence) {
            return RuntimeObservation.ResyncRequired
        }
        if (cursor == head) return null
        return requireNotNull(frames[slot(cursor.sequence + 1)])
    }

    private fun slot(sequence: Long): Int = (sequence % capacity).toInt()

    private companion object {
        const val MAX_SEQUENCE = 9_007_199_254_740_991L
        fun newEpoch(): String = UUID.randomUUID().toString()
    }
}
