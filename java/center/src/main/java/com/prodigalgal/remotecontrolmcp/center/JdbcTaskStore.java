package com.prodigalgal.remotecontrolmcp.center;

import com.prodigalgal.remotecontrolmcp.protocol.JsonCodec;
import com.prodigalgal.remotecontrolmcp.protocol.ArtifactResponse;
import com.prodigalgal.remotecontrolmcp.protocol.OutputResponse;
import com.prodigalgal.remotecontrolmcp.protocol.PollRequest;
import com.prodigalgal.remotecontrolmcp.protocol.PollResponse;
import com.prodigalgal.remotecontrolmcp.protocol.TaskCommand;
import com.prodigalgal.remotecontrolmcp.protocol.TaskKind;
import com.prodigalgal.remotecontrolmcp.protocol.TaskUpdateRequest;
import com.prodigalgal.remotecontrolmcp.protocol.SensitiveValueRedactor;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.Duration;
import java.security.MessageDigest;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.ArrayList;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * PostgreSQL task adapter. Every state transition and output append is one
 * transaction; TaskService keeps the in-memory adapter for protocol tests and
 * development without PostgreSQL.
 */
final class JdbcTaskStore {
    /**
     * Task projection used by list/poll/state paths.  Output and artifact
     * payloads are deliberately represented as NULL so PostgreSQL never
     * materializes potentially multi-megabyte bytea values for ordinary
     * heartbeats, task lists, or state transitions.
     */
    static final String SELECT_TASK_META = """
            SELECT t.task_id, t.agent_id, t.kind, t.required_capability, t.command_text,
                   t.cwd, t.environment, t.desktop_action, t.timeout_seconds,
                   t.idempotency_key, t.principal_id, t.connection_id, t.lane_key,
                   t.execution_session_id, t.result_channel, t.status, t.lease_until, t.attempt,
                   t.output_bytes, t.output_truncated, t.error_text, t.exit_code, t.created_at,
                   t.dispatched_at, t.started_at, t.finished_at, t.updated_at, t.execution_contract,
                   t.change_seq, t.progress_phase, t.progress_percent, t.progress_message,
                   t.progress_current, t.progress_total, t.progress_unit, t.progress_updated_at,
                   t.metadata_expires_at, t.output_expires_at, t.pinned, t.archived_at,
                   t.file_transfer_action,
                   NULL::bytea AS output_data, COALESCE(a.bytes, t.artifact_bytes, 0) AS artifact_bytes,
                   COALESCE(a.mime_type, t.artifact_mime) AS artifact_mime,
                   COALESCE(a.sha256, t.artifact_sha256) AS artifact_sha256
              FROM rcm_task t
              LEFT JOIN rcm_task_artifact a ON a.task_id = t.task_id
            """;

    private final JdbcTemplate jdbc;
    private final TransactionTemplate transactions;
    private final ArtifactStore artifactStore;
    private final McpQuotaService quota;

    JdbcTaskStore(JdbcTemplate jdbc, TransactionTemplate transactions) {
        this(jdbc, transactions, new InMemoryArtifactStore(), null);
    }

    JdbcTaskStore(JdbcTemplate jdbc, TransactionTemplate transactions, ArtifactStore artifactStore) {
        this(jdbc, transactions, artifactStore, null);
    }

    JdbcTaskStore(JdbcTemplate jdbc, TransactionTemplate transactions, ArtifactStore artifactStore,
                  McpQuotaService quota) {
        this.jdbc = Objects.requireNonNull(jdbc, "jdbc");
        this.transactions = Objects.requireNonNull(transactions, "transactions");
        this.artifactStore = Objects.requireNonNull(artifactStore, "artifactStore");
        this.quota = quota;
    }

    /** Configured-principal entry point for internal Agent/admin callers. */
    TaskView create(String taskId, String machineId, TaskCommand command, String idempotencyKey, Instant createdAt) {
        return create(taskId, machineId, command, idempotencyKey, createdAt, TaskOrigin.configured());
    }

    TaskView create(String taskId, String machineId, TaskCommand command, String idempotencyKey, Instant createdAt,
                    TaskOrigin origin) {
        var normalizedKey = idempotencyKey == null || idempotencyKey.isBlank() ? null : idempotencyKey;
        var normalizedOrigin = origin == null ? TaskOrigin.configured() : origin;
        try {
            return transactions.execute(status -> {
                if (quota != null) {
                    quota.assertTaskAdmissionInTransaction(normalizedOrigin, taskId, machineId, normalizedKey);
                }
                if (normalizedKey != null) {
                    var existing = findByIdempotency(machineId, normalizedOrigin.principalId(), normalizedKey, true);
                    if (existing != null) {
                        if (sameCommand(existing.command(), command)) {
                            return new TaskView(existing);
                        }
                        throw new IllegalArgumentException("idempotency key is already used with different task parameters");
                    }
                }
                var state = new TaskState(taskId, machineId, command, normalizedKey, createdAt, normalizedOrigin);
                insert(state);
                return new TaskView(state);
            });
        } catch (DuplicateKeyException race) {
            // Two MCP retries can pass the pre-check concurrently. The unique
            // database key wins; re-read the committed row and preserve the
            // idempotent response instead of exposing a spurious 500.
            if (normalizedKey != null) {
                var existing = findByIdempotency(machineId, normalizedOrigin.principalId(), normalizedKey, false);
                if (existing != null && sameCommand(existing.command(), command)) {
                    return new TaskView(existing);
                }
            }
            throw race;
        }
    }

    Optional<TaskState> find(String taskId) {
        if (taskId == null || taskId.isBlank()) {
            return Optional.empty();
        }
        return jdbc.query(SELECT_TASK_META + " WHERE t.task_id = ?", ps -> ps.setString(1, taskId.trim()),
                rs -> rs.next() ? Optional.of(readState(rs)) : Optional.empty());
    }

    Optional<TaskState> findIdempotent(String machineId, String principalId, String key) {
        return Optional.ofNullable(findByIdempotency(machineId, principalId, key, false));
    }

    boolean isDurableTask(String machineId, String taskId) {
        return Boolean.TRUE.equals(jdbc.query("""
                SELECT (agent_id = ? AND status NOT IN (?, ?, ?) AND timeout_seconds <= 0)
                  FROM rcm_task WHERE task_id = ?
                """, ps -> {
            ps.setString(1, machineId);
            ps.setString(2, TaskStatus.COMPLETED);
            ps.setString(3, TaskStatus.FAILED);
            ps.setString(4, TaskStatus.CANCELED);
            ps.setString(5, taskId);
        }, rs -> rs.next() && rs.getBoolean(1)));
    }

    List<TaskView> list(int offset, int limit) {
        return jdbc.query(SELECT_TASK_META + " ORDER BY t.created_at DESC, t.task_id DESC OFFSET ? LIMIT ?", ps -> {
            ps.setInt(1, offset);
            ps.setInt(2, limit);
        }, (rs, rowNum) -> new TaskView(readState(rs)));
    }

    Map<String, Long> taskStatusCounts() {
        var counts = new java.util.TreeMap<String, Long>();
        jdbc.query("SELECT status, COUNT(*) AS count FROM rcm_task GROUP BY status ORDER BY status",
                (rs, rowNum) -> {
                    counts.put(rs.getString("status"), rs.getLong("count"));
                    return null;
                });
        return Map.copyOf(counts);
    }

    long outputBytesTotal() {
        var value = jdbc.queryForObject("SELECT COALESCE(SUM(output_bytes), 0) FROM rcm_task", Long.class);
        return value == null ? 0L : value;
    }

    TaskService.TaskSloMetrics sloMetrics(Instant now) {
        var counts = new java.util.HashMap<String, Long>();
        jdbc.query("SELECT status, COUNT(*) AS count FROM rcm_task GROUP BY status", (rs, rowNum) -> {
            counts.put(rs.getString("status"), rs.getLong("count"));
            return null;
        });
        var queued = counts.getOrDefault(TaskStatus.QUEUED, 0L);
        var active = counts.getOrDefault(TaskStatus.DISPATCHING, 0L)
                + counts.getOrDefault(TaskStatus.RUNNING, 0L)
                + counts.getOrDefault(TaskStatus.CANCEL_REQUESTED, 0L);
        var terminal = counts.getOrDefault(TaskStatus.COMPLETED, 0L)
                + counts.getOrDefault(TaskStatus.FAILED, 0L)
                + counts.getOrDefault(TaskStatus.CANCELED, 0L);
        var oldestQueued = jdbc.queryForObject("""
                SELECT COALESCE(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - MIN(created_at))), 0)
                  FROM rcm_task WHERE status = ?
                """, Double.class, TaskStatus.QUEUED);
        var expiredLeases = jdbc.queryForObject("""
                SELECT COUNT(*) FROM rcm_task
                 WHERE status IN (?, ?, ?) AND lease_until IS NOT NULL AND lease_until <= CURRENT_TIMESTAMP
                """, Long.class, TaskStatus.DISPATCHING, TaskStatus.RUNNING, TaskStatus.CANCEL_REQUESTED);
        var outputBytes = jdbc.queryForObject("SELECT COALESCE(SUM(output_bytes), 0) FROM rcm_task", Long.class);
        var artifact = jdbc.query("""
                SELECT COUNT(*) AS objects, COALESCE(SUM(bytes), 0) AS bytes
                  FROM rcm_task_artifact
                """, rs -> rs.next() ? new long[]{rs.getLong("objects"), rs.getLong("bytes")} : new long[]{0L, 0L});
        var artifactObjects = artifact == null ? 0L : artifact[0];
        var artifactBytes = artifact == null ? 0L : artifact[1];
        return new TaskService.TaskSloMetrics(queued, active, terminal,
                counts.getOrDefault(TaskStatus.COMPLETED, 0L),
                counts.getOrDefault(TaskStatus.FAILED, 0L),
                counts.getOrDefault(TaskStatus.CANCELED, 0L),
                oldestQueued == null ? 0L : Math.max(0L, Math.round(oldestQueued)),
                expiredLeases == null ? 0L : expiredLeases,
                outputBytes == null ? 0L : outputBytes, artifactObjects, artifactBytes);
    }

    long taskCount() {
        var value = jdbc.queryForObject("SELECT COUNT(*) FROM rcm_task", Long.class);
        return value == null ? 0L : value;
    }

    TaskView cancel(String taskId) {
        return transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) {
                throw new IllegalArgumentException("task not found");
            }
            if (!TaskStatus.terminal(task.status())) {
                var next = TaskStatus.QUEUED.equals(task.status()) ? TaskStatus.CANCELED : TaskStatus.CANCEL_REQUESTED;
                var finished = TaskStatus.CANCELED.equals(next) ? Instant.now() : null;
                jdbc.update("""
                        UPDATE rcm_task
                           SET status = ?, finished_at = ?, lease_until = ?, updated_at = CURRENT_TIMESTAMP
                         WHERE task_id = ?
                        """, next, timestamp(finished), TaskStatus.CANCELED.equals(next) ? null : timestamp(task.leaseUntil()), task.id());
                task.status(next);
                task.finishedAt(finished);
                if (TaskStatus.CANCELED.equals(next)) {
                    task.leaseUntil(null);
                }
            }
            return new TaskView(task);
        });
    }

    PollResponse poll(String machineId, PollRequest request) {
        return pollWithRecovery(machineId, request).response();
    }

    List<String> recoverExpiredLeasesForMachine(String machineId) {
        return transactions.execute(status -> recoverExpiredLeases(machineId));
    }

    PollResult pollWithRecovery(String machineId, PollRequest request) {
        var availableSlots = request == null || request.availableSlots() == null ? 0 : request.availableSlots();
        var capabilities = request == null || request.availableCapabilities() == null ? List.<String>of() : request.availableCapabilities();
        return transactions.execute(status -> {
            // Lease repair is scoped to the authenticated Agent. A global
            // table sweep on every long-poll request would turn a large fleet
            // into repeated full-table scans; tasks are bound to one Agent,
            // so other machines are repaired when their own session polls.
            var recoveredTaskIds = recoverExpiredLeases(machineId);
            renewRunningLeases(machineId, request);
            var cancelIds = jdbc.queryForList("""
                    SELECT task_id FROM rcm_task
                     WHERE agent_id = ? AND status = ?
                     ORDER BY created_at LIMIT 64
                    """, String.class, machineId, TaskStatus.CANCEL_REQUESTED);
            if (availableSlots <= 0 || capabilities.isEmpty()) {
                return new PollResult(new PollResponse(null, cancelIds, null, null), recoveredTaskIds);
            }
            // Lock only the row that can actually be returned.  Locking a
            // larger batch and filtering capabilities in Java would make a
            // concurrent Center replica SKIP LOCKED every remaining queued
            // row, causing a false "no task" response to the other poller.
            // Capability values remain bind parameters; only the placeholder
            // count is assembled from the already bounded request list.
            var capabilityPlaceholders = String.join(", ", java.util.Collections.nCopies(capabilities.size(), "?"));
            var quotaPredicate = quota == null ? "TRUE" : """
                    (COALESCE(t.principal_id, '') = 'owner/configured-mcp'
                     OR (SELECT COUNT(*) FROM rcm_task principal_active
                           WHERE principal_active.principal_id = t.principal_id
                             AND principal_active.status IN ('dispatching', 'running', 'cancel_requested')) < ?)
                    """;
            var queued = jdbc.query((SELECT_TASK_META + """
                     WHERE t.agent_id = ? AND t.status = ?
                       AND t.required_capability IN (%s)
                       AND (t.kind <> 'file_transfer'
                            OR COALESCE(t.file_transfer_action ->> 'direction', '') <> 'web_to_agent'
                            OR EXISTS (
                                SELECT 1 FROM rcm_file_transfer inbound
                                 WHERE inbound.task_id = t.task_id
                                   AND inbound.status IN ('ready', 'delivering', 'delivered')
                            ))
                        AND NOT EXISTS (
                            SELECT 1 FROM rcm_task active
                             WHERE active.lane_key = t.lane_key
                               AND (
                                   active.agent_id = t.agent_id
                                   OR (
                                       COALESCE(t.execution_contract ->> 'host_id', '') <> ''
                                       AND COALESCE(t.execution_contract ->> 'host_id', '') = COALESCE(active.execution_contract ->> 'host_id', '')
                                       AND (
                                           (COALESCE(t.execution_contract ->> 'lane_mode', '') = 'exclusive'
                                               AND t.required_capability = 'desktop')
                                           OR t.required_capability = 'browser'
                                       )
                                   )
                               )
                               AND active.status IN (?, ?, ?)
                              AND NOT (
                                  COALESCE(t.execution_contract ->> 'lane_mode', 'write') = 'read'
                                  AND COALESCE(active.execution_contract ->> 'lane_mode', 'write') = 'read'
                              )
                       )
                        AND (%s)
                     ORDER BY t.created_at, t.task_id
                     LIMIT 1 FOR UPDATE OF t SKIP LOCKED
                    """).formatted(capabilityPlaceholders, quotaPredicate), ps -> {
                var index = 1;
                ps.setString(index++, machineId);
                ps.setString(index++, TaskStatus.QUEUED);
                for (var capability : capabilities) ps.setString(index++, capability);
                ps.setString(index++, TaskStatus.DISPATCHING);
                ps.setString(index++, TaskStatus.RUNNING);
                ps.setString(index++, TaskStatus.CANCEL_REQUESTED);
                if (quota != null) ps.setInt(index, quota.maxActiveTasks());
            }, (rs, rowNum) -> readState(rs));
            var selected = queued.stream()
                    .filter(task -> capabilities.contains(task.command().requiredCapability()))
                    .findFirst();
            if (selected.isEmpty()) {
            return new PollResult(new PollResponse(null, cancelIds, null, null), recoveredTaskIds);
            }
            var task = selected.get();
            var now = Instant.now();
            var lease = now.plus(TaskService.LEASE_DURATION);
            jdbc.update("""
                    UPDATE rcm_task
                       SET status = ?, dispatched_at = ?, lease_until = ?, attempt = attempt + 1,
                           updated_at = CURRENT_TIMESTAMP
                     WHERE task_id = ? AND status = ?
                    """, TaskStatus.DISPATCHING, timestamp(now), timestamp(lease), task.id(), TaskStatus.QUEUED);
            task.status(TaskStatus.DISPATCHING);
            task.attempt(task.attempt() + 1);
            task.dispatchedAt(now);
            task.leaseUntil(lease);
            return new PollResult(new PollResponse(task.command().withAttempt(task.attempt()), cancelIds, null, null), recoveredTaskIds);
        });
    }

    record PollResult(PollResponse response, List<String> recoveredTaskIds) {
        PollResult {
            response = response == null ? new PollResponse(null, List.of(), null, null) : response;
            recoveredTaskIds = recoveredTaskIds == null ? List.of() : List.copyOf(recoveredTaskIds);
        }
    }

    TaskView updateState(String machineId, String taskId, TaskUpdateRequest update, Integer attempt) {
        return transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) {
                throw new IllegalArgumentException("task not found");
            }
            if (!task.machineId().equals(machineId)) {
                throw new SecurityException("task does not belong to this machine");
            }
            assertAttempt(task, attempt);
            var next = update.status().trim().toLowerCase();
            if (!validStatus(next)) {
                throw new IllegalArgumentException("unsupported task status: " + next);
            }
            if (!allowedTransition(task.status(), next)) {
                throw new IllegalArgumentException("invalid task transition: " + task.status() + " -> " + next);
            }
            // Center observations keep task chronology independent of Agent clocks.
            // Terminal updates usually omit started_at; preserve the first observation.
            var started = task.startedAt() == null && TaskStatus.RUNNING.equals(next) ? Instant.now() : task.startedAt();
            var finished = TaskStatus.terminal(next) && task.finishedAt() == null ? Instant.now() : task.finishedAt();
            var error = update.error() == null || update.error().isBlank() ? task.error() : compactError(update.error());
            var truncated = task.outputTruncated() || update.outputTruncated();
            jdbc.update("""
                    UPDATE rcm_task
                       SET status = ?, exit_code = ?, error_text = ?, started_at = ?, finished_at = ?,
                           output_truncated = ?, lease_until = ?, updated_at = CURRENT_TIMESTAMP
                     WHERE task_id = ? AND agent_id = ?
                    """, next, update.exitCode() == null ? task.exitCode() : update.exitCode(), error,
                    timestamp(started), timestamp(finished), truncated,
                    TaskStatus.terminal(next) ? null : timestamp(task.leaseUntil()), taskId, machineId);
            task.status(next);
            if (update.exitCode() != null) task.exitCode(update.exitCode());
            task.error(error);
            task.startedAt(started);
            task.finishedAt(finished);
            task.outputTruncated(truncated);
            if (TaskStatus.terminal(next)) task.leaseUntil(null);
            return new TaskView(task);
        });
    }

    TaskView updateProgress(String machineId, String taskId,
                            com.prodigalgal.remotecontrolmcp.protocol.TaskProgressUpdate progress,
                            Integer attempt) {
        return transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) throw new IllegalArgumentException("task not found");
            if (!task.machineId().equals(machineId)) {
                throw new SecurityException("task does not belong to this machine");
            }
            assertAttempt(task, attempt);
            jdbc.update("""
                    UPDATE rcm_task
                       SET progress_phase = ?, progress_percent = ?, progress_message = ?,
                           progress_current = ?, progress_total = ?, progress_unit = ?,
                           progress_updated_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
                     WHERE task_id = ? AND agent_id = ?
                    """, progress.phase(), progress.percent(), progress.message(), progress.current(),
                    progress.total(), progress.unit(), taskId, machineId);
            task.progressPhase(progress.phase());
            task.progressPercent(progress.percent());
            task.progressMessage(progress.message());
            task.progressCurrent(progress.current());
            task.progressTotal(progress.total());
            task.progressUnit(progress.unit());
            task.progressUpdatedAt(Instant.now());
            task.bumpChangeSequence();
            return new TaskView(task);
        });
    }

    TaskView updateState(String machineId, String taskId, TaskUpdateRequest update) {
        return updateState(machineId, taskId, update, currentAttempt(machineId, taskId));
    }

    TaskView updateFileTransferAction(String machineId, String taskId,
                                      com.prodigalgal.remotecontrolmcp.protocol.FileTransferAction action) {
        return transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) throw new IllegalArgumentException("task not found");
            if (!task.machineId().equals(machineId)) throw new SecurityException("task does not belong to this machine");
            if (task.command().kind() != TaskKind.FILE_TRANSFER) throw new IllegalArgumentException("task is not a file transfer");
            if (!TaskStatus.QUEUED.equals(task.status())) throw new IllegalStateException("file transfer task is no longer queued");
            var json = new String(JsonCodec.write(action), StandardCharsets.UTF_8);
            jdbc.update("UPDATE rcm_task SET file_transfer_action = CAST(? AS jsonb), updated_at = CURRENT_TIMESTAMP WHERE task_id = ? AND agent_id = ? AND status = ?",
                    json, taskId, machineId, TaskStatus.QUEUED);
            var command = task.command();
            task.command(new TaskCommand(command.id(), command.kind(), command.requiredCapability(), command.command(), command.cwd(),
                    command.env(), command.timeoutSeconds(), command.desktop(), command.createdAt(), command.contract(), command.attempt(), action));
            return new TaskView(task);
        });
    }

    TaskView failPreparedFileTransfer(String machineId, String taskId, String error) {
        return transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) throw new IllegalArgumentException("task not found");
            if (!task.machineId().equals(machineId)) throw new SecurityException("task does not belong to this machine");
            if (TaskStatus.QUEUED.equals(task.status())) {
                var safe = error == null || error.isBlank() ? "file transfer preparation failed" : compactError(error);
                var now = Instant.now();
                jdbc.update("UPDATE rcm_task SET status = ?, error_text = ?, finished_at = ?, lease_until = NULL, updated_at = CURRENT_TIMESTAMP WHERE task_id = ? AND agent_id = ? AND status = ?",
                        TaskStatus.FAILED, safe, timestamp(now), taskId, machineId, TaskStatus.QUEUED);
                task.status(TaskStatus.FAILED);
                task.error(safe);
                task.finishedAt(now);
                task.leaseUntil(null);
            }
            return new TaskView(task);
        });
    }

    void assertCurrentAttempt(String machineId, String taskId, Integer attempt) {
        transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) throw new IllegalArgumentException("task not found");
            if (!task.machineId().equals(machineId)) throw new SecurityException("task does not belong to this machine");
            assertAttempt(task, attempt);
            return null;
        });
    }

    OutputResponse appendOutput(String machineId, String taskId, long offset, byte[] data, Integer attempt) {
        if (offset < 0 || data == null || data.length > TaskService.MAX_OUTPUT_CHUNK_BYTES) {
            throw new IllegalArgumentException("offset and data are required; output chunks are limited to 256 KiB");
        }
        return transactions.execute(status -> {
            // Lock only the small task row.  The output blob stays in
            // PostgreSQL; replay validation reads just the overlapping slice
            // and a new chunk is appended in-place, avoiding an O(n) Java
            // byte-array copy for every upload.
            var task = findForUpdateMeta(taskId);
            if (task == null) throw new IllegalArgumentException("task not found");
            if (!task.machineId().equals(machineId)) throw new SecurityException("task does not belong to this machine");
            assertAttempt(task, attempt);
            var currentBytes = task.outputBytes();
            if (offset > currentBytes) throw new IllegalArgumentException("output offset is ahead of the confirmed cursor");
            if (offset > Integer.MAX_VALUE - 1L) throw new IllegalArgumentException("output offset is outside the supported range");
            var overlap = Math.toIntExact(Math.min((long) data.length, currentBytes - offset));
            if (overlap > 0) {
                var existing = jdbc.query("""
                        SELECT substring(output_data FROM ? FOR ?) AS output_data
                          FROM rcm_task_output
                         WHERE task_id = ?
                        """, ps -> {
                    ps.setInt(1, Math.toIntExact(offset) + 1);
                    ps.setInt(2, overlap);
                    ps.setString(3, taskId.trim());
                }, rs -> rs.next() ? rs.getBytes("output_data") : null);
                if (existing == null || existing.length != overlap || !Arrays.equals(existing, Arrays.copyOf(data, overlap))) {
                    throw new IllegalArgumentException("output replay does not match the confirmed bytes");
                }
            }
            var appendFrom = overlap;
            var remaining = Math.max(0L, TaskService.outputLimit(task) - currentBytes);
            var appendLength = Math.toIntExact(Math.min((long) data.length - appendFrom, remaining));
            if (appendLength > 0) {
                var append = Arrays.copyOfRange(data, appendFrom, appendFrom + appendLength);
                var outputRows = jdbc.update("""
                        UPDATE rcm_task_output
                           SET output_data = COALESCE(output_data, ''::bytea) || CAST(? AS bytea),
                               updated_at = CURRENT_TIMESTAMP
                         WHERE task_id = ?
                        """, append, taskId);
                if (outputRows == 0) {
                    jdbc.update("INSERT INTO rcm_task_output(task_id, output_data, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)", taskId, append);
                }
            }
            if (appendFrom + appendLength < data.length) task.outputTruncated(true);
            var nextOffset = currentBytes + appendLength;
            task.outputBytes(nextOffset);
            jdbc.update("UPDATE rcm_task SET output_bytes = ?, output_truncated = ?, updated_at = CURRENT_TIMESTAMP WHERE task_id = ?",
                    nextOffset, task.outputTruncated(), taskId);
            return new OutputResponse(nextOffset);
        });
    }

    OutputResponse appendOutput(String machineId, String taskId, long offset, byte[] data) {
        return appendOutput(machineId, taskId, offset, data, currentAttempt(machineId, taskId));
    }

    OutputPage readOutput(String taskId, long cursor, int limit) {
        if (taskId == null || taskId.isBlank()) throw new IllegalArgumentException("taskId is required");
        if (cursor < 0 || cursor > Integer.MAX_VALUE - 1L) {
            throw new IllegalArgumentException("cursor is outside the supported output range");
        }
        if (limit <= 0 || limit > TaskService.MAX_OUTPUT_PAGE) {
            throw new IllegalArgumentException("limit is outside the supported output range");
        }
        var start = Math.toIntExact(cursor) + 1;
        var slice = jdbc.query("""
                SELECT t.output_bytes, t.output_truncated, t.status,
                       COALESCE(substring(o.output_data FROM ? FOR ?), ''::bytea) AS output_data
                  FROM rcm_task t
                  LEFT JOIN rcm_task_output o ON o.task_id = t.task_id
                 WHERE t.task_id = ?
                """, ps -> {
            ps.setInt(1, start);
            ps.setInt(2, limit);
            ps.setString(3, taskId.trim());
        }, rs -> {
            if (!rs.next()) throw new IllegalArgumentException("task not found");
            var data = rs.getBytes("output_data");
            return new OutputSlice(rs.getLong("output_bytes"), rs.getBoolean("output_truncated"),
                    rs.getString("status"), data == null ? new byte[0] : data);
        });
        if (cursor > slice.outputBytes()) throw new IllegalArgumentException("cursor is ahead of output");
        var next = cursor + slice.data().length;
        return new OutputPage(slice.data(), cursor, next,
                next < slice.outputBytes() || (!TaskStatus.terminal(slice.status()) && slice.truncated()));
    }

    ArtifactResponse appendArtifact(String machineId, String taskId, String mimeType, String sha256, byte[] data) {
        return appendArtifact(machineId, taskId, mimeType, sha256, data, currentAttempt(machineId, taskId));
    }

    ArtifactResponse appendArtifact(String machineId, String taskId, String mimeType, String sha256,
                                    byte[] data, Integer attempt) {
        return transactions.execute(status -> {
            var task = findForUpdateMeta(taskId);
            if (task == null) throw new IllegalArgumentException("task not found");
            if (!task.machineId().equals(machineId)) throw new SecurityException("task does not belong to this machine");
            assertAttempt(task, attempt);
            if (data.length > TaskService.artifactLimit(task)) {
                throw new IllegalArgumentException("artifact exceeds the execution contract limit of "
                        + TaskService.artifactLimit(task) + " bytes");
            }
            var existing = jdbc.query("SELECT storage_backend, object_key, sha256, mime_type, bytes FROM rcm_task_artifact WHERE task_id = ? FOR UPDATE",
                    ps -> ps.setString(1, taskId), rs -> {
                        if (!rs.next()) return null;
                        return new ArtifactRow(rs.getString("storage_backend"), rs.getString("object_key"),
                                rs.getString("sha256"), rs.getString("mime_type"), rs.getLong("bytes"));
                    });
            if (existing != null) {
                if (!existing.sha256().equalsIgnoreCase(sha256)) throw new IllegalArgumentException("task already has a different artifact");
                if (existing.bytes() > 0 && existing.bytes() != data.length) {
                    throw new IllegalArgumentException("task artifact bytes do not match the existing digest");
                }
                if (existing.objectKey() == null || existing.objectKey().isBlank()) {
                    throw new ArtifactStore.StorageException("artifact metadata has no object key");
                }
                return new ArtifactResponse(data.length, sha256);
            }
            var objectKey = artifactStore.put(taskId, sha256, data);
            jdbc.update("""
                    INSERT INTO rcm_task_artifact(task_id, mime_type, storage_backend, object_key, bytes, sha256, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    """, taskId, mimeType, artifactStore.backend(), objectKey, data.length, sha256);
            task.artifactBytes(data.length);
            task.artifactMime(mimeType);
            task.artifactSha256(sha256);
            task.artifactData(new byte[0]);
            return new ArtifactResponse(data.length, sha256);
        });
    }

    Optional<TaskService.ArtifactData> readArtifact(String taskId) {
        if (taskId == null || taskId.isBlank()) return Optional.empty();
        var row = jdbc.query("SELECT mime_type, storage_backend, object_key, bytes, sha256 FROM rcm_task_artifact WHERE task_id = ?",
                ps -> ps.setString(1, taskId.trim()), rs -> {
                    if (!rs.next()) return null;
                    return new ArtifactRow(rs.getString("storage_backend"), rs.getString("object_key"),
                            rs.getString("sha256"), rs.getString("mime_type"), rs.getLong("bytes"));
                });
        if (row == null) return Optional.empty();
        if (row.objectKey() == null || row.objectKey().isBlank()) return Optional.empty();
        byte[] data = artifactStore.read(row.objectKey());
        if (data.length != row.bytes() || !sha256(data).equalsIgnoreCase(row.sha256())) {
            throw new ArtifactStore.StorageException("artifact metadata does not match stored bytes");
        }
        return Optional.of(new TaskService.ArtifactData(row.mimeType(), row.sha256(), data));
    }

    /** Update only the task's bounded artifact projection after a streamed transfer. */
    void recordTransferArtifact(String machineId, String taskId, String mimeType, long bytes, String sha256) {
        var updated = jdbc.update("""
                UPDATE rcm_task
                   SET artifact_bytes = ?, artifact_mime = ?, artifact_sha256 = ?,
                       updated_at = CURRENT_TIMESTAMP
                 WHERE task_id = ? AND agent_id = ?
                """, bytes, mimeType, sha256, taskId, machineId);
        if (updated == 0) throw new IllegalArgumentException("task not found for transfer artifact");
    }

    TaskService.ArtifactGcResult gcArtifacts(Instant cutoff, int limit) {
        var candidates = transactions.execute(status -> {
            var rows = jdbc.query("""
                    SELECT a.task_id, a.object_key, a.bytes
                      FROM rcm_task_artifact a
                      JOIN rcm_task t ON t.task_id = a.task_id
                     WHERE a.created_at <= ?
                       AND t.status IN (?, ?, ?)
                     ORDER BY a.created_at, a.task_id
                     LIMIT ?
                     FOR UPDATE OF a
                    """, ps -> {
                ps.setTimestamp(1, timestamp(cutoff));
                ps.setString(2, TaskStatus.COMPLETED);
                ps.setString(3, TaskStatus.FAILED);
                ps.setString(4, TaskStatus.CANCELED);
                ps.setInt(5, limit);
            }, (rs, rowNum) -> new ArtifactCandidate(rs.getString("task_id"), rs.getString("object_key"), rs.getLong("bytes")));
            if (rows.isEmpty()) return List.<ArtifactCandidate>of();
            var deleted = new ArrayList<ArtifactCandidate>(rows.size());
            for (var row : rows) {
                var removed = row.objectKey() == null
                        ? jdbc.update("DELETE FROM rcm_task_artifact WHERE task_id = ? AND object_key IS NULL", row.taskId())
                        : jdbc.update("DELETE FROM rcm_task_artifact WHERE task_id = ? AND object_key = ?", row.taskId(), row.objectKey());
                if (removed > 0) {
                    // Keep the task projection honest after retention: a
                    // deleted artifact must not continue to advertise stale
                    // bytes/MIME/SHA-256 to MCP or the console.  The metadata
                    // row is already locked in this transaction.
                    jdbc.update("""
                            UPDATE rcm_task
                               SET artifact_bytes = 0, artifact_mime = NULL,
                                   artifact_sha256 = NULL, updated_at = CURRENT_TIMESTAMP
                             WHERE task_id = ?
                            """, row.taskId());
                    deleted.add(row);
                }
            }
            return List.copyOf(deleted);
        });
        var deletedObjects = 0;
        var deleteFailures = 0;
        long reclaimedBytes = 0L;
        for (var candidate : candidates) {
            try {
                artifactStore.delete(candidate.objectKey());
                deletedObjects++;
                reclaimedBytes = saturatingAdd(reclaimedBytes, candidate.bytes());
            } catch (RuntimeException failure) {
                // Metadata is already gone, so keep the response successful and
                // expose the count.  A later filesystem sweep can remove an
                // orphan; task execution is never coupled to GC availability.
                deleteFailures++;
            }
        }
        // A process crash can leave a filesystem object after the metadata
        // transaction has rolled back (put happens before the INSERT).  Take
        // a small authoritative key snapshot and let the backend remove only
        // objects older than a grace period.  The grace period closes the
        // concurrent upload race; an enumerating backend may safely return
        // zero when it cannot provide this operation.
        var referenced = jdbc.query("""
                SELECT object_key FROM rcm_task_artifact
                 WHERE storage_backend = ? AND object_key IS NOT NULL
                """, ps -> ps.setString(1, artifactStore.backend()),
                (rs, rowNum) -> rs.getString("object_key"));
        try {
            deletedObjects += artifactStore.sweepOrphans(java.util.Set.copyOf(referenced),
                    Instant.now().minus(Duration.ofHours(1)), limit);
        } catch (RuntimeException failure) {
            deleteFailures++;
        }
        return new TaskService.ArtifactGcResult(candidates.size(), deletedObjects, deleteFailures, reclaimedBytes);
    }

    TaskService.TaskRetentionGcResult gcExpiredTasks(Instant metadataCutoff, Instant outputCutoff, int limit) {
        var outputRows = transactions.execute(status -> {
            var ids = jdbc.query("""
                    SELECT task_id
                      FROM rcm_task
                     WHERE status IN (?, ?, ?) AND pinned = FALSE
                       AND output_expires_at IS NOT NULL AND output_expires_at <= ?
                       AND output_bytes > 0
                     ORDER BY output_expires_at, task_id
                     LIMIT ? FOR UPDATE SKIP LOCKED
                    """, ps -> {
                ps.setString(1, TaskStatus.COMPLETED);
                ps.setString(2, TaskStatus.FAILED);
                ps.setString(3, TaskStatus.CANCELED);
                ps.setTimestamp(4, timestamp(outputCutoff));
                ps.setInt(5, limit);
            }, (rs, rowNum) -> rs.getString("task_id"));
            for (var taskId : ids) {
                jdbc.update("UPDATE rcm_task_output SET output_data = CAST(? AS bytea), updated_at = CURRENT_TIMESTAMP WHERE task_id = ?",
                        new byte[0], taskId);
                jdbc.update("UPDATE rcm_task SET output_bytes = 0, output_truncated = TRUE, updated_at = CURRENT_TIMESTAMP WHERE task_id = ?",
                        taskId);
            }
            return ids.size();
        });
        var metadataRows = transactions.execute(status -> {
            var ids = jdbc.query("""
                    SELECT task_id
                      FROM rcm_task
                     WHERE status IN (?, ?, ?) AND pinned = FALSE
                       AND metadata_expires_at IS NOT NULL AND metadata_expires_at <= ?
                     ORDER BY metadata_expires_at, task_id
                     LIMIT ? FOR UPDATE SKIP LOCKED
                    """, ps -> {
                ps.setString(1, TaskStatus.COMPLETED);
                ps.setString(2, TaskStatus.FAILED);
                ps.setString(3, TaskStatus.CANCELED);
                ps.setTimestamp(4, timestamp(metadataCutoff));
                ps.setInt(5, limit);
            }, (rs, rowNum) -> rs.getString("task_id"));
            for (var taskId : ids) {
                jdbc.update("DELETE FROM rcm_task WHERE task_id = ?", taskId);
            }
            return ids.size();
        });
        return new TaskService.TaskRetentionGcResult(metadataRows, outputRows);
    }

    private void insert(TaskState state) {
        var command = state.command();
        var env = new String(JsonCodec.write(command.env()), StandardCharsets.UTF_8);
        var desktop = command.desktop() == null ? null : new String(JsonCodec.write(command.desktop()), StandardCharsets.UTF_8);
        var fileTransfer = command.fileTransfer() == null ? null : new String(JsonCodec.write(command.fileTransfer()), StandardCharsets.UTF_8);
        var contract = command.contract() == null ? null : new String(JsonCodec.write(command.contract()), StandardCharsets.UTF_8);
        jdbc.update("""
                INSERT INTO rcm_task (
                    task_id, agent_id, kind, required_capability, command_text, cwd,
                    environment, desktop_action, timeout_seconds, idempotency_key,
                    principal_id, connection_id, lane_key, execution_session_id, result_channel,
                    status, lease_until, attempt, output_bytes, output_truncated,
                    error_text, created_at, dispatched_at, started_at, finished_at, updated_at, execution_contract,
                    metadata_expires_at, output_expires_at, pinned, archived_at, file_transfer_action
                ) VALUES (?, ?, ?, ?, ?, ?, CAST(? AS jsonb), CAST(? AS jsonb), ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, false, ?, ?, ?, ?, ?, ?, CAST(? AS jsonb), ?, ?, false, ?, CAST(? AS jsonb))
                """, state.id(), state.machineId(), command.kind().wireValue(), command.requiredCapability(), command.command(),
                command.cwd(), env, desktop, command.timeoutSeconds(), state.idempotencyKey(), state.origin().principalId(),
                state.origin().connectionId(), state.laneKey(), state.executionSessionId(), state.resultChannel(),
                state.status(), null,
                null, timestamp(state.createdAt()), null, null, null, timestamp(state.createdAt()), contract,
                timestamp(state.metadataExpiresAt()), timestamp(state.outputExpiresAt()), timestamp(state.archivedAt()), fileTransfer);
        jdbc.update("INSERT INTO rcm_task_output(task_id, output_data, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)", state.id(), new byte[0]);
    }

    private TaskState findForUpdateMeta(String taskId) {
        if (taskId == null || taskId.isBlank()) return null;
        return jdbc.query(SELECT_TASK_META + " WHERE t.task_id = ? FOR UPDATE OF t", ps -> ps.setString(1, taskId.trim()),
                rs -> rs.next() ? readState(rs) : null);
    }

    private TaskState findByIdempotency(String machineId, String principalId, String key, boolean forUpdate) {
        var suffix = forUpdate ? " FOR UPDATE OF t" : "";
        return jdbc.query(SELECT_TASK_META + " WHERE t.agent_id = ? AND t.principal_id = ? AND t.idempotency_key = ?" + suffix, ps -> {
            ps.setString(1, machineId);
            ps.setString(2, principalId);
            ps.setString(3, key);
        }, rs -> rs.next() ? readState(rs) : null);
    }

    private List<String> recoverExpiredLeases(String machineId) {
        // Lock the small, machine-scoped set before repairing it.  This keeps
        // concurrent Center replicas from both observing the same expired
        // lease while still avoiding a fleet-wide sweep.
        var expired = jdbc.query("""
                SELECT task_id
                  FROM rcm_task
                 WHERE agent_id = ?
                   AND lease_until IS NOT NULL
                   AND lease_until <= CURRENT_TIMESTAMP
                   AND status IN (?, ?, ?)
                 ORDER BY task_id
                 FOR UPDATE
                """, ps -> {
            ps.setString(1, machineId);
            ps.setString(2, TaskStatus.DISPATCHING);
            ps.setString(3, TaskStatus.RUNNING);
            ps.setString(4, TaskStatus.CANCEL_REQUESTED);
        }, (rs, rowNum) -> rs.getString("task_id"));
        if (expired.isEmpty()) return List.of();
        jdbc.update("""
                UPDATE rcm_task SET status = ?, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE agent_id = ? AND status = ? AND lease_until IS NOT NULL AND lease_until <= CURRENT_TIMESTAMP
                """, TaskStatus.QUEUED, machineId, TaskStatus.DISPATCHING);
        jdbc.update("""
                UPDATE rcm_task SET status = ?, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE agent_id = ? AND status = ? AND timeout_seconds <= 0
                   AND lease_until IS NOT NULL AND lease_until <= CURRENT_TIMESTAMP
                """, TaskStatus.QUEUED, machineId, TaskStatus.RUNNING);
        jdbc.update("""
                UPDATE rcm_task SET status = ?, error_text = ?,
                       finished_at = CURRENT_TIMESTAMP, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE agent_id = ? AND status = ? AND timeout_seconds > 0
                   AND lease_until IS NOT NULL AND lease_until <= CURRENT_TIMESTAMP
                """, TaskStatus.FAILED, "agent lease expired; command outcome unknown; inspect machine before retry",
                machineId, TaskStatus.RUNNING);
        jdbc.update("""
                UPDATE rcm_task SET status = ?, finished_at = CURRENT_TIMESTAMP,
                       lease_until = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE agent_id = ? AND status = ?
                   AND lease_until IS NOT NULL AND lease_until <= CURRENT_TIMESTAMP
                """, TaskStatus.CANCELED, machineId, TaskStatus.CANCEL_REQUESTED);
        return List.copyOf(expired);
    }

    private void renewRunningLeases(String machineId, PollRequest request) {
        if (request == null || request.runningTaskIds() == null || request.runningTaskIds().isEmpty()) return;
        var now = Instant.now();
        var lease = now.plus(TaskService.LEASE_DURATION);
        // Bind one task id per statement instead of relying on a driver-specific
        // ARRAY binding for `ANY (?)`; this works with both PostgreSQL JDBC and
        // lightweight recording templates used by protocol tests.
        for (var taskId : request.runningTaskIds()) {
            if (taskId == null || taskId.isBlank()) continue;
                    jdbc.update("""
                        UPDATE rcm_task SET status = CASE WHEN status IN (?, ?) AND timeout_seconds <= 0 THEN ? ELSE status END,
                        started_at = CASE WHEN status IN (?, ?) AND timeout_seconds <= 0 AND started_at IS NULL THEN ? ELSE started_at END,
                        lease_until = CASE WHEN status = ? OR (status IN (?, ?) AND timeout_seconds <= 0) THEN ? ELSE lease_until END,
                        updated_at = CURRENT_TIMESTAMP
                     WHERE agent_id = ? AND task_id = ? AND status IN (?, ?, ?) AND (timeout_seconds <= 0 OR status = ?)
                    """, TaskStatus.DISPATCHING, TaskStatus.QUEUED, TaskStatus.RUNNING,
                    TaskStatus.DISPATCHING, TaskStatus.QUEUED, timestamp(now),
                    TaskStatus.RUNNING, TaskStatus.DISPATCHING, TaskStatus.QUEUED, timestamp(lease), machineId, taskId,
                    TaskStatus.DISPATCHING, TaskStatus.RUNNING, TaskStatus.QUEUED, TaskStatus.RUNNING);
        }
    }

    private static TaskState readState(ResultSet rs) throws SQLException {
        var taskId = rs.getString("task_id");
        var kind = TaskKind.fromWireValue(rs.getString("kind"));
        var environment = readEnvironment(rs.getString("environment"));
        var desktopJson = rs.getString("desktop_action");
        var desktop = desktopJson == null || desktopJson.isBlank() ? null : JsonCodec.read(desktopJson.getBytes(StandardCharsets.UTF_8), TaskCommand.DesktopAction.class);
        var transferJson = rs.getString("file_transfer_action");
        var transfer = transferJson == null || transferJson.isBlank() ? null
                : JsonCodec.read(transferJson.getBytes(StandardCharsets.UTF_8), com.prodigalgal.remotecontrolmcp.protocol.FileTransferAction.class);
        var contractJson = rs.getString("execution_contract");
        var contract = contractJson == null || contractJson.isBlank() ? null
                : JsonCodec.read(contractJson.getBytes(StandardCharsets.UTF_8), com.prodigalgal.remotecontrolmcp.protocol.ExecutionContract.class);
        var command = new TaskCommand(taskId, kind, rs.getString("required_capability"), rs.getString("command_text"),
                rs.getString("cwd"), environment, rs.getInt("timeout_seconds"), desktop, instant(rs, "created_at"), contract,
                rs.getInt("attempt"), transfer);
        var output = rs.getBytes("output_data");
        var artifactBytesValue = rs.getObject("artifact_bytes");
        var artifactBytes = artifactBytesValue instanceof Number number ? number.longValue() : 0L;
        var state = TaskState.restore(taskId, rs.getString("agent_id"), command, rs.getString("idempotency_key"), instant(rs, "created_at"),
                rs.getString("status"), rs.getInt("attempt"), numberValue(rs.getObject("exit_code")), rs.getString("error_text"),
                rs.getBoolean("output_truncated"), instant(rs, "dispatched_at"), instant(rs, "started_at"), instant(rs, "finished_at"),
                instant(rs, "lease_until"), output == null ? new byte[0] : output,
                artifactBytes, rs.getString("artifact_mime"), rs.getString("artifact_sha256"),
                new byte[0],
                new TaskOrigin(rs.getString("principal_id"), TaskOrigin.CONFIGURED_TOKEN, rs.getString("connection_id")),
                rs.getString("lane_key"), rs.getString("execution_session_id"), rs.getString("result_channel"));
        state.outputBytes(rs.getLong("output_bytes"));
        state.changeSequence(rs.getLong("change_seq"));
        state.progressPhase(rs.getString("progress_phase"));
        var percent = rs.getObject("progress_percent");
        state.progressPercent(percent instanceof Number number ? number.intValue() : null);
        state.progressMessage(rs.getString("progress_message"));
        var current = rs.getObject("progress_current");
        state.progressCurrent(current instanceof Number number ? number.longValue() : null);
        var total = rs.getObject("progress_total");
        state.progressTotal(total instanceof Number number ? number.longValue() : null);
        state.progressUnit(rs.getString("progress_unit"));
        state.progressUpdatedAt(instant(rs, "progress_updated_at"));
        state.metadataExpiresAt(instant(rs, "metadata_expires_at"));
        state.outputExpiresAt(instant(rs, "output_expires_at"));
        state.pinned(rs.getBoolean("pinned"));
        state.archivedAt(instant(rs, "archived_at"));
        return state;
    }

    private static Integer numberValue(Object value) {
        return value instanceof Number number ? number.intValue() : null;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> readEnvironment(String value) {
        if (value == null || value.isBlank()) return Map.of();
        var raw = JsonCodec.read(value.getBytes(StandardCharsets.UTF_8), Map.class);
        var result = new java.util.LinkedHashMap<String, String>();
        raw.forEach((key, item) -> result.put(String.valueOf(key), item == null ? "" : String.valueOf(item)));
        return Map.copyOf(result);
    }

    private static Instant instant(ResultSet rs, String column) throws SQLException {
        var timestamp = rs.getTimestamp(column);
        return timestamp == null ? null : timestamp.toInstant();
    }

    private static Timestamp timestamp(Instant value) {
        return value == null ? null : Timestamp.from(value);
    }

    private static boolean sameCommand(TaskCommand left, TaskCommand right) {
        return left.kind() == right.kind()
                && Objects.equals(left.requiredCapability(), right.requiredCapability())
                && Objects.equals(left.command(), right.command())
                && Objects.equals(left.cwd(), right.cwd())
                && Objects.equals(left.env(), right.env())
                && left.timeoutSeconds() == right.timeoutSeconds()
                && Objects.equals(left.desktop(), right.desktop())
                && Objects.equals(left.fileTransfer(), right.fileTransfer())
                && (left.contract() == null ? right.contract() == null : left.contract().sameIntent(right.contract()));
    }

    int currentAttempt(String machineId, String taskId) {
        var value = jdbc.queryForObject("SELECT attempt FROM rcm_task WHERE task_id = ? AND agent_id = ?", Integer.class,
                taskId, machineId);
        if (value == null || value < 1) throw new SecurityException("task dispatch attempt is required");
        return value;
    }

    private static void assertAttempt(TaskState task, Integer attempt) {
        if (attempt == null || attempt < 1) throw new SecurityException("task dispatch attempt is required");
        if (task.attempt() != attempt) {
            throw new SecurityException("stale task dispatch attempt");
        }
    }

    private static boolean validStatus(String status) {
        return TaskStatus.DISPATCHING.equals(status) || TaskStatus.RUNNING.equals(status)
                || TaskStatus.COMPLETED.equals(status) || TaskStatus.FAILED.equals(status) || TaskStatus.CANCELED.equals(status);
    }

    private static boolean allowedTransition(String current, String next) {
        // Retried HTTP updates can arrive after Center committed the first
        // request but before its response reached the Agent.
        if (Objects.equals(current, next)) {
            return true;
        }
        if (TaskStatus.QUEUED.equals(current)) return TaskStatus.CANCELED.equals(next) || TaskStatus.DISPATCHING.equals(next);
        if (TaskStatus.DISPATCHING.equals(current)) return TaskStatus.RUNNING.equals(next) || TaskStatus.FAILED.equals(next) || TaskStatus.CANCELED.equals(next);
        if (TaskStatus.RUNNING.equals(current) || TaskStatus.CANCEL_REQUESTED.equals(current)) {
            return TaskStatus.COMPLETED.equals(next) || TaskStatus.FAILED.equals(next) || TaskStatus.CANCELED.equals(next);
        }
        return false;
    }

    private static String compactError(String error) {
        var value = SensitiveValueRedactor.redact(error.trim());
        return value.length() <= 4096 ? value : value.substring(0, 4096);
    }

    private static String sha256(byte[] data) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (java.security.NoSuchAlgorithmException exception) {
            throw new ArtifactStore.StorageException("SHA-256 is unavailable", exception);
        }
    }

    private record OutputSlice(long outputBytes, boolean truncated, String status, byte[] data) {
    }

    private record ArtifactRow(String storageBackend, String objectKey, String sha256,
                               String mimeType, long bytes) {
    }

    private record ArtifactCandidate(String taskId, String objectKey, long bytes) {
    }

    private static long saturatingAdd(long left, long right) {
        if (right <= 0 || Long.MAX_VALUE - left < right) return Long.MAX_VALUE;
        return left + right;
    }
}
