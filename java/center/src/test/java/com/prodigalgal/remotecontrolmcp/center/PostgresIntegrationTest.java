package com.prodigalgal.remotecontrolmcp.center;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.prodigalgal.remotecontrolmcp.protocol.PollRequest;
import com.prodigalgal.remotecontrolmcp.protocol.RegisterRequest;
import com.prodigalgal.remotecontrolmcp.protocol.AgentMetadata;
import com.prodigalgal.remotecontrolmcp.protocol.AgentRuntimeDescriptor;
import com.prodigalgal.remotecontrolmcp.protocol.TaskCommand;
import com.prodigalgal.remotecontrolmcp.protocol.TaskKind;
import com.prodigalgal.remotecontrolmcp.protocol.TaskUpdateRequest;
import com.prodigalgal.remotecontrolmcp.protocol.UpgradeArtifact;
import com.prodigalgal.remotecontrolmcp.protocol.UpgradeComponentPlan;
import com.prodigalgal.remotecontrolmcp.protocol.UpgradeStatusRequest;
import com.prodigalgal.remotecontrolmcp.protocol.RegisterResponse;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Base64;
import java.util.Set;
import java.util.UUID;
import java.util.HashSet;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.stream.IntStream;
import liquibase.integration.spring.SpringLiquibase;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real PostgreSQL/Liquibase contract test. It is enabled only when the CI
 * (or a developer) explicitly provides RCM_TEST_POSTGRES_URL; ordinary local
 * JVM tests remain database-free and do not silently claim PostgreSQL
 * coverage.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@EnabledIfEnvironmentVariable(named = "RCM_TEST_POSTGRES_URL", matches = "\\S+")
class PostgresIntegrationTest {
    private HikariDataSource dataSource;
    private JdbcTemplate jdbc;
    private TransactionTemplate transactions;
    private String agentId;
    private String aclPrincipalId;

    @BeforeAll
    void migrateSchema() throws Exception {
        var config = new HikariConfig();
        config.setJdbcUrl(required("RCM_TEST_POSTGRES_URL"));
        config.setUsername(System.getenv().getOrDefault("RCM_TEST_POSTGRES_USERNAME", "postgres"));
        config.setPassword(System.getenv().getOrDefault("RCM_TEST_POSTGRES_PASSWORD", "postgres"));
        config.setPoolName("rcm-postgres-integration");
        config.setMaximumPoolSize(4);
        config.setMinimumIdle(1);
        config.setConnectionTimeout(5_000);
        config.setInitializationFailTimeout(10_000);
        dataSource = new HikariDataSource(config);
        jdbc = new JdbcTemplate(dataSource);
        transactions = new TransactionTemplate(new JdbcTransactionManager(dataSource));

        var liquibase = new SpringLiquibase();
        liquibase.setDataSource(dataSource);
        liquibase.setChangeLog("classpath:db/changelog/db.changelog-master.yaml");
        liquibase.setContexts("postgres");
        liquibase.setShouldRun(true);
        liquibase.afterPropertiesSet();
    }

    @AfterAll
    void cleanUp() {
        // Tasks owned by the ACL principal are removed with their machine
        // before deleting the principal referenced by those durable rows.
        if (jdbc != null && agentId != null) {
            jdbc.update("DELETE FROM rcm_agent WHERE agent_id = ?", agentId);
        }
        if (jdbc != null && aclPrincipalId != null) {
            jdbc.update("DELETE FROM rcm_principal WHERE principal_id = ?", aclPrincipalId);
        }
        if (dataSource != null) {
            dataSource.close();
        }
    }

    @Test
    void durableOAuthRefreshRetainsSourceCredentialAndHonorsRevocation() throws Exception {
        var beans = new StaticListableBeanFactory();
        beans.addBean("jdbc", jdbc);
        beans.addBean("transactions", transactions);
        beans.addBean("access", new McpAccessService(jdbc));
        var principals = new McpPrincipalService(beans.getBeanProvider(JdbcTemplate.class),
                beans.getBeanProvider(TransactionTemplate.class), beans.getBeanProvider(McpAccessService.class));
        var resource = "https://remote-control-mcp-center.example.com";
        var clientId = "https://chatgpt.com/oauth/client.json";
        var redirect = "https://chatgpt.com/connector_platform_oauth_redirect";
        var config = new CenterOAuthConfig(Map.of("RCM_CENTER_OAUTH_ENABLED", "true",
                "RCM_CENTER_OAUTH_ISSUER", resource, "RCM_CENTER_OAUTH_RESOURCE", resource));
        var principalId = "oauth_it_" + UUID.randomUUID().toString().replace("-", "");
        try {
            var source = principals.issue(new McpPrincipalService.IssueRequest(principalId, "OAuth integration",
                    3600L, Set.of("mcp:read", "mcp:execute"), Map.of("oauth-it-machine", Set.of("command", "task_read"))));
            var service = new McpOAuthService(config, principals, beans.getBeanProvider(JdbcTemplate.class),
                    beans.getBeanProvider(TransactionTemplate.class));
            var verifier = "postgres-oauth-verifier-with-more-than-forty-three-characters";
            var challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
                    MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)));
            var code = service.issueAuthorizationCode(clientId, redirect, challenge, "S256",
                    "mcp:read mcp:execute offline_access", resource, source.token());
            var issued = service.exchangeAuthorizationCode(clientId, redirect, code.code(), verifier, resource);

            // A new facade must rotate the durable refresh token without an
            // in-memory code or token cache, and preserve its source ACL.
            var restarted = new McpOAuthService(config, principals, beans.getBeanProvider(JdbcTemplate.class),
                    beans.getBeanProvider(TransactionTemplate.class));
            var refreshed = restarted.refresh(clientId, issued.refreshToken(), resource);
            assertEquals(source.tokenId(), restarted.resolve(refreshed.accessToken()).orElseThrow().tokenId());
            assertThrows(McpOAuthService.OAuthException.class,
                    () -> restarted.refresh(clientId, issued.refreshToken(), resource));
            var pending = restarted.issueAuthorizationCode(clientId, redirect, challenge, "S256",
                    "mcp:read", resource, source.token());

            assertTrue(principals.revoke(source.tokenId()));
            assertTrue(restarted.resolve(issued.accessToken()).isEmpty());
            assertTrue(restarted.resolve(refreshed.accessToken()).isEmpty());
            assertThrows(McpOAuthService.OAuthException.class,
                    () -> restarted.refresh(clientId, refreshed.refreshToken(), resource));
            assertThrows(McpOAuthService.OAuthException.class,
                    () -> restarted.exchangeAuthorizationCode(clientId, redirect, pending.code(), verifier, resource));
        } finally {
            jdbc.update("DELETE FROM rcm_principal WHERE principal_id = ?", principalId);
        }
    }

    @Test
    void liquibaseSchemaSupportsRegistrationTaskLeaseOutputAndArtifactRoundTrip() throws Exception {
        agentId = "machine_it_" + UUID.randomUUID().toString().replace("-", "");
        var registry = AgentRegistry.forTest("integration-enrollment", jdbc);
        var request = new RegisterRequest(
                "postgres-it-agent-" + agentId,
                "postgres-it-host",
                "postgres-it-host",
                "linux",
                "amd64",
                "integration",
                "/tmp",
                List.of("command", "durable_tasks", "file_transfer"));
        var registration = registry.register(request, "integration-enrollment");
        agentId = registration.machineId();
        assertNotNull(jdbc.queryForObject("SELECT agent_id FROM rcm_agent WHERE agent_id = ?", String.class, agentId));

        // A new Center facade must authenticate and read the same durable
        // identity immediately after a process restart; no in-memory registry
        // cache may be required for daily Agent traffic.
        var restartedRegistry = AgentRegistry.forTest("integration-enrollment", jdbc);
        assertTrue(restartedRegistry.findMachine(agentId, Instant.now()).isPresent());
        assertTrue(restartedRegistry.acceptsAgent(agentId, registration.token()));

        var runtime = new AgentRuntimeDescriptor(1, 7, 2, 1,
                32L * 1024 * 1024, 96L * 1024 * 1024, 12, 900, 0, 0, false, true);
        var heartbeat = new AgentMetadata(request.name(), request.hostId(),
                "postgres-it-host", "linux", "amd64", "integration-2", "/tmp",
                List.of("command", "browser", "file_transfer"), runtime);
        registry.poll(agentId, registration.token(), new PollRequest(List.of(), 1,
                List.of("command", "browser"), heartbeat));
        var persistedRuntime = restartedRegistry.findMachine(agentId, Instant.now()).orElseThrow().runtime();
        assertEquals(7, persistedRuntime.configGeneration());
        assertEquals(2, persistedRuntime.maxConcurrency());
        assertTrue(persistedRuntime.browserAdapterConfigured());

        var sessions = new ExecutionSessionService(jdbc, transactions);
        var taskService = new TaskService(registry, jdbc, transactions, sessions);

        // Permissions belong to each issued credential and are bounded to a
        // machine/tool pair rather than shared by every token for a principal.
        aclPrincipalId = "acl_it_" + UUID.randomUUID().toString().replace("-", "");
        jdbc.update("""
                INSERT INTO rcm_principal(principal_id, kind, display_name, status, created_at, updated_at)
                VALUES (?, 'user', ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """, aclPrincipalId, "ACL integration user");
        var access = new McpAccessService(jdbc);
        jdbc.update("""
                INSERT INTO rcm_mcp_token(token_id, principal_id, token_hash, display_name, scope_json,
                                          expires_at, revoked_at, created_at)
                VALUES ('acl-token', ?, ?, 'ACL token', '[\"mcp:read\",\"mcp:execute\"]'::jsonb,
                        NULL, NULL, CURRENT_TIMESTAMP)
                """, aclPrincipalId, UUID.randomUUID().toString().replace("-", "").repeat(2));
        var aclOrigin = new TaskOrigin(aclPrincipalId, "acl-token", "acl-conversation");
        org.junit.jupiter.api.Assertions.assertThrows(SecurityException.class,
                () -> access.authorizeTool(aclOrigin, agentId, "command"));
        access.grantTokenMachines("acl-token", java.util.Map.of(agentId,
                java.util.Set.of("command", "task_read")));
        access.authorizeTool(aclOrigin, agentId, "command");
        org.junit.jupiter.api.Assertions.assertThrows(SecurityException.class,
                () -> access.authorizeTool(aclOrigin, agentId, "browser"));

        // Exercise the production JDBC session path across actual connection
        // ids. Memory-only tests cannot detect an extra SQL conversation fence.
        var recoveryCommand = new TaskCommand("", TaskKind.COMMAND, "command", "echo recoverable", "/tmp",
                Map.of(), 30, null, Instant.now());
        var recoveryTask = taskService.create(new CreateTaskRequest(agentId, recoveryCommand, "reconnect-it"), "mcp", aclOrigin);
        var recoveryLease = taskService.poll(agentId, new PollRequest(List.of(), 1, List.of("command"))).task();
        assertEquals(recoveryTask.id(), recoveryLease.id());
        taskService.updateState(agentId, recoveryTask.id(), new TaskUpdateRequest(TaskStatus.RUNNING, null, null, null, null, false), recoveryLease.attempt());
        taskService.appendOutput(agentId, recoveryTask.id(), 0, "recoverable\n".getBytes(StandardCharsets.UTF_8), recoveryLease.attempt());
        taskService.updateState(agentId, recoveryTask.id(), new TaskUpdateRequest(TaskStatus.COMPLETED, 0, null, null, null, false), recoveryLease.attempt());
        var reconnected = new TaskOrigin(aclPrincipalId, "acl-token", "new-transport");
        var readRequest = new io.modelcontextprotocol.spec.McpSchema.CallToolRequest("task_read", Map.of("task_id", recoveryTask.id()), Map.of());
        var recovered = McpConfiguration.taskReadModel(taskService, access, reconnected, readRequest);
        assertTrue(!Boolean.TRUE.equals(recovered.isError()), recovered.content().toString());
        assertEquals("recoverable\n", ((Map<?, ?>) ((Map<?, ?>) recovered.structuredContent()).get("output")).get("text"));
        var outsider = new TaskOrigin("another-principal", "another-token", "new-transport");
        assertTrue(Boolean.TRUE.equals(McpConfiguration.taskReadModel(taskService, access, outsider, readRequest).isError()));
        access.grantTokenMachines("acl-token", Map.of(agentId, Set.of("command")));
        assertTrue(Boolean.TRUE.equals(McpConfiguration.taskReadModel(taskService, access, reconnected, readRequest).isError()));
        access.grantTokenMachines("acl-token", Map.of(agentId, Set.of("command", "task_read")));
        jdbc.update("UPDATE rcm_mcp_token SET revoked_at = CURRENT_TIMESTAMP WHERE token_id = 'acl-token'");
        assertTrue(Boolean.TRUE.equals(McpConfiguration.taskReadModel(taskService, access, reconnected, readRequest).isError()));
        jdbc.update("UPDATE rcm_mcp_token SET revoked_at = NULL WHERE token_id = 'acl-token'");

        // Test wildcard machine grant
        var wildcardPrincipal = "acl_wc_" + UUID.randomUUID().toString().replace("-", "");
        jdbc.update("""
                INSERT INTO rcm_principal(principal_id, kind, display_name, status, created_at, updated_at)
                VALUES (?, 'user', ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """, wildcardPrincipal, "Wildcard integration user");
        jdbc.update("""
                INSERT INTO rcm_mcp_token(token_id, principal_id, token_hash, display_name, scope_json,
                                          expires_at, revoked_at, created_at)
                VALUES ('wc-token', ?, ?, 'Wildcard token', '[\"mcp:read\",\"mcp:execute\"]'::jsonb,
                        NULL, NULL, CURRENT_TIMESTAMP)
                """, wildcardPrincipal, UUID.randomUUID().toString().replace("-", "").repeat(2));
        access.grantTokenMachines("wc-token", java.util.Map.of("*", java.util.Set.of("command", "task_read")));
        var wildcardOrigin = new TaskOrigin(wildcardPrincipal, "wc-token", "wc-conv");
        org.junit.jupiter.api.Assertions.assertDoesNotThrow(() -> access.authorizeTool(wildcardOrigin, agentId, "command"));

        var store = new JdbcTaskStore(jdbc, transactions);
        var taskId = "task_it_" + UUID.randomUUID().toString().replace("-", "");
        var command = new TaskCommand(taskId, TaskKind.COMMAND, "command", "printf integration", "/tmp",
                Map.of("RCM_IT", "1"), 0, null, Instant.now());
        var first = store.create(taskId, agentId, command, "integration-key", command.createdAt());
        var replay = store.create("task_it_replay", agentId, command, "integration-key", command.createdAt());
        assertEquals(first.id(), replay.id(), "idempotent retry must return the committed task");
        var persistedCorrelation = store.find(taskId).orElseThrow();
        assertEquals("internal", persistedCorrelation.executionSessionId());
        assertEquals("rcm.task." + taskId, persistedCorrelation.resultChannel());

        var poll = store.poll(agentId, new PollRequest(List.of(), 1, List.of("command"),
                new AgentMetadata(request.name(), request.hostId(), request.hostname(), request.os(), request.arch(),
                        request.version(), request.defaultCwd(), request.capabilities())));
        assertNotNull(poll.task());
        assertEquals(taskId, poll.task().id());
        assertEquals(1, store.find(taskId).orElseThrow().attempt(), "first lease claim must be attempt 1");
        var skewedClock = first.createdAt().minusSeconds(90);
        store.updateState(agentId, taskId, new TaskUpdateRequest("running", null, null, skewedClock, null, false));
        var observedStart = store.find(taskId).orElseThrow().startedAt();
        assertNotNull(observedStart); assertTrue(!observedStart.isBefore(first.createdAt()));

        var firstOutput = "line-1\n".getBytes(StandardCharsets.UTF_8);
        var secondOutput = "line-2\n".getBytes(StandardCharsets.UTF_8);
        assertEquals(firstOutput.length, store.appendOutput(agentId, taskId, 0, firstOutput).nextOffset());
        assertEquals(firstOutput.length + secondOutput.length,
                store.appendOutput(agentId, taskId, firstOutput.length, secondOutput).nextOffset());
        // Replaying an already confirmed chunk is accepted without appending
        // it twice, which is the key disconnect/retry invariant.
        assertEquals(firstOutput.length + secondOutput.length,
                store.appendOutput(agentId, taskId, 0, concat(firstOutput, secondOutput)).nextOffset());
        var output = store.readOutput(taskId, 0, 64 * 1024);
        assertArrayEquals(concat(firstOutput, secondOutput), output.data());
        assertEquals(firstOutput.length + secondOutput.length, output.nextCursor());

        var artifact = "artifact-data".getBytes(StandardCharsets.UTF_8);
        var digest = sha256(artifact);
        assertEquals(artifact.length, store.appendArtifact(agentId, taskId, "text/plain", digest, artifact).bytes());
        assertEquals("filesystem", jdbc.queryForObject("SELECT storage_backend FROM rcm_task_artifact WHERE task_id = ?", String.class, taskId));
        assertNull(jdbc.queryForObject("SELECT artifact_data FROM rcm_task_artifact WHERE task_id = ?", byte[].class, taskId),
                "new artifacts must not be written into PostgreSQL bytea");
        assertTrue(store.readArtifact(taskId).isPresent());
        store.updateState(agentId, taskId, new TaskUpdateRequest("completed", 0, null, null, skewedClock.plusSeconds(2), false));
        assertEquals(TaskStatus.COMPLETED, store.find(taskId).orElseThrow().status());
        assertEquals(0, store.find(taskId).orElseThrow().exitCode());
        var observedFinish = store.find(taskId).orElseThrow().finishedAt();
        assertEquals(observedStart, store.find(taskId).orElseThrow().startedAt(), "terminal update must retain started_at in PostgreSQL");
        assertTrue(!observedFinish.isBefore(observedStart));
        store.updateState(agentId, taskId, new TaskUpdateRequest("completed", 0, null, null, skewedClock, false));
        assertEquals(observedFinish, store.find(taskId).orElseThrow().finishedAt());

        // File-transfer v2 uses a separate streaming object and metadata row.
        // Exercise the durable state machine, an idempotent upload replay, and
        // a new Center facade reading the same signed artifact after restart.
        var transferStore = new FileSystemArtifactStore(Path.of(System.getProperty("java.io.tmpdir"),
                "rcm-postgres-transfer-" + UUID.randomUUID()));
        var transferTokens = new CenterTokenConfig() {
            @Override
            public String artifactDownloadSecret() {
                return "postgres-transfer-test-secret";
            }
        };
        var transfers = new ArtifactTransferService(jdbc, transactions, transferStore, taskService, transferTokens);
        // Use the built-in shared principal so transfer-only rows do not make
        // the ACL fixture's principal undeletable during @AfterAll cleanup.
        var transferOrigin = TaskOrigin.configured();
        var transferRequest = new CreateTaskRequest(agentId,
                new TaskCommand("", TaskKind.COMMAND, "command", "printf transfer", "/tmp", Map.of(), 0, null, Instant.now()),
                "transfer-v2-key", null, "", "low", false, transferOrigin);
        var transfer = transfers.createAgentToWeb(transferOrigin, transferRequest, "/tmp/transfer-report.txt",
                "transfer-report.txt", "text/plain");
        var transferLease = taskService.poll(agentId, new PollRequest(List.of(), 1, List.of("file_transfer"))).task();
        assertNotNull(transferLease);
        var transferData = "postgres transfer".getBytes(StandardCharsets.UTF_8);
        var transferHash = sha256(transferData);
        var delivered = transfers.receiveFromAgent(agentId, transfer.transfer().transferId(),
                new ByteArrayInputStream(transferData), transferData.length, transferHash,
                "transfer-report.txt", "text/plain", transferLease.attempt());
        assertEquals("delivered", delivered.status());
        store.updateState(agentId, transferLease.id(),
                new TaskUpdateRequest("running", null, null, Instant.now(), null, false), transferLease.attempt());
        store.updateState(agentId, transferLease.id(),
                new TaskUpdateRequest("completed", 0, null, null, Instant.now(), false), transferLease.attempt());
        assertEquals("delivered", jdbc.queryForObject("SELECT status FROM rcm_file_transfer WHERE transfer_id = ?", String.class,
                transfer.transfer().transferId()));
        assertEquals(transferData.length, jdbc.queryForObject("SELECT bytes_transferred FROM rcm_file_transfer WHERE transfer_id = ?", Long.class,
                transfer.transfer().transferId()));
        var transferReplay = transfers.receiveFromAgent(agentId, transfer.transfer().transferId(),
                new ByteArrayInputStream(transferData), transferData.length, transferHash,
                "transfer-report.txt", "text/plain", transferLease.attempt());
        assertEquals(delivered.status(), transferReplay.status());
        var restartedTransfers = new ArtifactTransferService(jdbc, transactions, transferStore, taskService, transferTokens);
        assertEquals("delivered", restartedTransfers.findByTransfer(transfer.transfer().transferId(), transferOrigin).orElseThrow().status());

        var resumable = transfers.createAgentToWeb(transferOrigin,
                new CreateTaskRequest(agentId,
                        new TaskCommand("", TaskKind.COMMAND, "command", "printf resumable", "/tmp", Map.of(), 0, null, Instant.now()),
                        "transfer-v2-resume-key", null, "", "low", false, transferOrigin),
                "/tmp/transfer-resumable.txt", "transfer-resumable.txt", "text/plain");
        var resumableData = "postgres resumable transfer".getBytes(StandardCharsets.UTF_8);
        var resumableHash = sha256(resumableData);
        var resumableLease = taskService.poll(agentId, new PollRequest(List.of(), 1, List.of("file_transfer"))).task();
        assertNotNull(resumableLease);
        var split = 9;
        var partial = transfers.receiveFromAgentChunk(agentId, resumable.transfer().transferId(),
                new ByteArrayInputStream(java.util.Arrays.copyOfRange(resumableData, 0, split)), split, 0,
                resumableData.length, resumableHash, "transfer-resumable.txt", "text/plain", resumableLease.attempt());
        assertEquals("delivering", partial.status());
        var restartedResumable = new ArtifactTransferService(jdbc, transactions, transferStore, taskService, transferTokens);
        assertEquals(split, restartedResumable.resumeFromAgent(agentId, resumable.transfer().transferId(), resumableLease.attempt()).offset());
        var resumed = restartedResumable.receiveFromAgentChunk(agentId, resumable.transfer().transferId(),
                new ByteArrayInputStream(java.util.Arrays.copyOfRange(resumableData, split, resumableData.length)),
                resumableData.length - split, split, resumableData.length, resumableHash,
                "transfer-resumable.txt", "text/plain", resumableLease.attempt());
        assertEquals("delivered", resumed.status());
        store.updateState(agentId, resumableLease.id(),
                new TaskUpdateRequest("running", null, null, Instant.now(), null, false), resumableLease.attempt());
        store.updateState(agentId, resumableLease.id(),
                new TaskUpdateRequest("completed", 0, null, null, Instant.now(), false), resumableLease.attempt());
        assertEquals(resumableData.length, jdbc.queryForObject("SELECT bytes_transferred FROM rcm_file_transfer WHERE transfer_id = ?", Long.class,
                resumable.transfer().transferId()));

        // A transport retry can race with the original request.  The unique
        // (agent_id, idempotency_key) constraint plus the adapter's duplicate
        // recovery must return one committed task to every caller.
        var concurrentCommand = new TaskCommand("concurrent-command", TaskKind.COMMAND, "command", "printf concurrent", "/tmp",
                Map.of(), 30, null, Instant.now());
        var start = new CountDownLatch(1);
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var futures = IntStream.range(0, 8).mapToObj(index -> executor.submit(() -> {
                start.await();
                return store.create("task_it_race_" + index, agentId, concurrentCommand, "concurrent-key", concurrentCommand.createdAt());
            })).toList();
            start.countDown();
            var ids = new HashSet<String>();
            for (var future : futures) ids.add(future.get().id());
            assertEquals(1, ids.size(), "concurrent idempotency requests must converge on one task");
            // The race task is only a uniqueness probe. Remove it from the
            // queue so the following lease-recovery assertions select their
            // own task deterministically.
            var raceTaskId = ids.iterator().next();
            store.cancel(raceTaskId);
            var canceledRace = store.find(raceTaskId).orElseThrow();
            assertEquals(TaskStatus.CANCELED, canceledRace.status());
        }

        // Two independent Center facades must be able to claim different
        // queued rows at the same time.  The row lock/SKIP LOCKED contract is
        // what permits multiple Center replicas without double dispatch.
        var claimIds = IntStream.range(0, 2).mapToObj(index -> {
            // The test uses read-only commands so both can share the same
            // machine lane while the Center replicas exercise SKIP LOCKED.
            var claimCommand = new TaskCommand("", TaskKind.COMMAND, "command", "printf claim-" + index, "/tmp/claim-" + index,
                    Map.of(), 30, null, Instant.now());
            return taskService.create(new CreateTaskRequest(agentId, claimCommand, "claim-key-" + index,
                    null, "claim-session-" + index, "low", false, TaskOrigin.configured(), true)).id();
        }).toList();
        var claimStart = new CountDownLatch(1);
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var futures = claimIds.stream().map(ignored -> executor.submit(() -> {
                claimStart.await();
                return new JdbcTaskStore(jdbc, transactions).poll(agentId,
                        new PollRequest(List.of(), 1, List.of("command"))).task();
            })).toList();
            claimStart.countDown();
            var claimed = new HashSet<String>();
            for (var future : futures) {
                var claimedTask = future.get();
                assertNotNull(claimedTask, "each concurrent Center poll must claim a task");
                claimed.add(claimedTask.id());
            }
            assertEquals(2, claimed.size(), "concurrent polls must not double-dispatch one task");
            // Release both claimed rows before the following lease-recovery
            // assertions.  Leaving dispatching rows alive would make this
            // test depend on an Agent callback that it does not run.
            for (var claimedId : claimed) {
                var claimedTask = store.find(claimedId).orElseThrow();
                store.updateState(agentId, claimedId,
                        new TaskUpdateRequest("running", null, null, Instant.now(), null, false),
                        claimedTask.attempt());
                store.updateState(agentId, claimedId,
                        new TaskUpdateRequest("completed", 0, null, null, Instant.now(), false),
                        claimedTask.attempt());
            }
        }

        // A bounded command may legitimately outlive the two-minute dispatch
        // lease. Polling must renew its RUNNING lease just like a durable task,
        // without removing its original started_at or dispatch-attempt fence.
        var boundedTaskId = "task_it_bounded_renew_" + UUID.randomUUID().toString().replace("-", "");
        var boundedCommand = new TaskCommand(boundedTaskId, TaskKind.COMMAND, "command", "printf bounded", "/tmp",
                Map.of(), 210, null, Instant.now());
        store.create(boundedTaskId, agentId, boundedCommand, "bounded-renew-key", boundedCommand.createdAt());
        var boundedLease = store.poll(agentId, new PollRequest(List.of(), 1, List.of("command"))).task();
        assertEquals(boundedTaskId, boundedLease.id());
        store.updateState(agentId, boundedTaskId,
                new TaskUpdateRequest(TaskStatus.RUNNING, null, null, null, null, false), boundedLease.attempt());
        var boundedStartedAt = store.find(boundedTaskId).orElseThrow().startedAt();
        jdbc.update("UPDATE rcm_task SET lease_until = CURRENT_TIMESTAMP + INTERVAL '5 seconds' WHERE task_id = ?", boundedTaskId);
        store.poll(agentId, new PollRequest(List.of(boundedTaskId), 0, List.of("command")));
        var renewedBounded = store.find(boundedTaskId).orElseThrow();
        assertTrue(renewedBounded.leaseUntil().isAfter(Instant.now().plusSeconds(90)),
                "a live bounded task must not expire while its Agent keeps polling");
        assertEquals(boundedStartedAt, renewedBounded.startedAt());
        assertEquals(boundedLease.attempt(), renewedBounded.attempt());
        store.updateState(agentId, boundedTaskId,
                new TaskUpdateRequest(TaskStatus.COMPLETED, 0, null, null, null, false), boundedLease.attempt());

        // An Agent that disappears after a lease is claimed must not leave a
        // task permanently dispatching. A subsequent poll requeues and claims
        // it, while a fresh adapter instance can still read the same state.
        var leaseTaskId = "task_it_lease_" + UUID.randomUUID().toString().replace("-", "");
        var leaseCommand = new TaskCommand(leaseTaskId, TaskKind.COMMAND, "command", "printf lease", "/tmp",
                Map.of(), 30, null, Instant.now());
        store.create(leaseTaskId, agentId, leaseCommand, "lease-key", leaseCommand.createdAt());
        assertEquals(leaseTaskId, store.poll(agentId, new PollRequest(List.of(), 1, List.of("command"))).task().id());
        jdbc.update("UPDATE rcm_task SET lease_until = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE task_id = ?", leaseTaskId);
        var reclaimed = store.poll(agentId, new PollRequest(List.of(), 1, List.of("command")));
        assertEquals(leaseTaskId, reclaimed.task().id(), "expired dispatch lease must be reclaimed");
        assertEquals(2, store.find(leaseTaskId).orElseThrow().attempt(), "reclaimed lease must increment attempt");
        var restartedStore = new JdbcTaskStore(jdbc, transactions);
        assertEquals(TaskStatus.DISPATCHING, restartedStore.find(leaseTaskId).orElseThrow().status());
        // The task is intentionally left dispatching for the restart read
        // above, then finalized so the next durable-lease scenario can use
        // the same host lane without an Agent callback.
        var reclaimedLease = store.find(leaseTaskId).orElseThrow();
        store.updateState(agentId, leaseTaskId,
                new TaskUpdateRequest("running", null, null, Instant.now(), null, false),
                reclaimedLease.attempt());
        store.updateState(agentId, leaseTaskId,
                new TaskUpdateRequest("completed", 0, null, null, Instant.now(), false),
                reclaimedLease.attempt());

        // A no-timeout process recovered by the same Agent advertises its
        // durable task ID and renews the expired lease without dispatching a
        // second process. Timed tasks cannot be safely replayed and therefore
        // become an explicit failure after their lease expires.
        var durableLeaseId = "task_it_durable_" + UUID.randomUUID().toString().replace("-", "");
        var durableLeaseCommand = new TaskCommand(durableLeaseId, TaskKind.COMMAND, "command", "printf durable", "/tmp",
                Map.of(), 0, null, Instant.now());
        store.create(durableLeaseId, agentId, durableLeaseCommand, "durable-lease-key", durableLeaseCommand.createdAt());
        assertEquals(durableLeaseId, store.poll(agentId, new PollRequest(List.of(), 1, List.of("command"))).task().id());
        store.updateState(agentId, durableLeaseId, new TaskUpdateRequest("running", null, null, Instant.now(), null, false));
        jdbc.update("UPDATE rcm_task SET lease_until = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE task_id = ?", durableLeaseId);
        var durableReconnect = store.poll(agentId, new PollRequest(List.of(durableLeaseId), 1, List.of("command")));
        assertNull(durableReconnect.task());
        assertEquals(TaskStatus.RUNNING, store.find(durableLeaseId).orElseThrow().status());
        var renewedDurable = store.find(durableLeaseId).orElseThrow();
        store.updateState(agentId, durableLeaseId,
                new TaskUpdateRequest("completed", 0, null, null, Instant.now(), false),
                renewedDurable.attempt());

        var timedLeaseId = "task_it_timed_" + UUID.randomUUID().toString().replace("-", "");
        var timedLeaseCommand = new TaskCommand(timedLeaseId, TaskKind.COMMAND, "command", "printf timed", "/tmp",
                Map.of(), 30, null, Instant.now());
        store.create(timedLeaseId, agentId, timedLeaseCommand, "timed-lease-key", timedLeaseCommand.createdAt());
        assertEquals(timedLeaseId, store.poll(agentId, new PollRequest(List.of(durableLeaseId), 1, List.of("command"))).task().id());
        store.updateState(agentId, timedLeaseId, new TaskUpdateRequest("running", null, null, Instant.now(), null, false));
        jdbc.update("UPDATE rcm_task SET lease_until = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE task_id = ?", timedLeaseId);
        store.poll(agentId, new PollRequest(List.of(durableLeaseId), 1, List.of("command")));
        assertEquals(TaskStatus.FAILED, store.find(timedLeaseId).orElseThrow().status());

        var cancelLeaseId = "task_it_cancel_" + UUID.randomUUID().toString().replace("-", "");
        var cancelCommand = new TaskCommand(cancelLeaseId, TaskKind.COMMAND, "command", "printf cancel", "/tmp",
                Map.of(), 0, null, Instant.now());
        store.create(cancelLeaseId, agentId, cancelCommand, "cancel-lease-key", cancelCommand.createdAt());
        assertEquals(cancelLeaseId, store.poll(agentId, new PollRequest(List.of(), 1, List.of("command"))).task().id());
        store.updateState(agentId, cancelLeaseId, new TaskUpdateRequest("running", null, null, Instant.now(), null, false));
        var afterCancelId = "task_it_after_cancel_" + UUID.randomUUID().toString().replace("-", "");
        var afterCancelCommand = new TaskCommand(afterCancelId, TaskKind.COMMAND, "command", "printf next", "/tmp",
                Map.of(), 0, null, Instant.now());
        store.create(afterCancelId, agentId, afterCancelCommand, "after-cancel-lease-key", afterCancelCommand.createdAt());
        store.cancel(cancelLeaseId);
        jdbc.update("UPDATE rcm_task SET lease_until = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE task_id = ?", cancelLeaseId);
        var recoveredCancel = store.poll(agentId, new PollRequest(List.of(), 1, List.of("command")));
        assertEquals(TaskStatus.CANCELED, store.find(cancelLeaseId).orElseThrow().status());
        assertTrue(recoveredCancel.cancelTaskIds().isEmpty(), "a recovered cancel request must no longer be sent to the Agent");
        assertEquals(afterCancelId, recoveredCancel.task().id(), "expired cancellation must release the execution lane");
    }

    private static byte[] concat(byte[] first, byte[] second) {
        var result = new byte[first.length + second.length];
        System.arraycopy(first, 0, result, 0, first.length);
        System.arraycopy(second, 0, result, first.length, second.length);
        return result;
    }

    @Test
    void upgradeRetryBudgetAndPartialProofSurviveRestartWithoutBlockingOtherBatches() throws Exception {
        var registry = AgentRegistry.forTest("upgrade-enroll", jdbc);
        var prefix = "upgrade-it-" + UUID.randomUUID().toString().replace("-", "");
        var first = registry.register(upgradeRegistration(prefix + "-a", "v1.0.0"), "upgrade-enroll");
        var flaky = registry.register(upgradeRegistration(prefix + "-b", "v1.0.0"), "upgrade-enroll");
        var third = registry.register(upgradeRegistration(prefix + "-c", "v1.0.0"), "upgrade-enroll");
        var offline = registry.register(upgradeRegistration(prefix + "-offline", "v1.0.0"), "upgrade-enroll");
        var ids = List.of(first.machineId(), flaky.machineId(), third.machineId(), offline.machineId());
        String campaignId = null;
        String otherCampaignId = null;
        try {
            jdbc.update("UPDATE rcm_agent SET last_seen_at = CURRENT_TIMESTAMP - INTERVAL '2 minutes' WHERE agent_id = ?", offline.machineId());
            var service = postgresUpgrades(registry);
            var updater = new UpgradeComponentPlan("agent-updater", "v1.0.0", "linux", "amd64",
                    "https://example.test/updater.zip", "a".repeat(64), 100L, "manual");
            var campaign = service.create(new CreateUpgradeCampaignRequest("v2.0.0", 1, 1, ids,
                    upgradeArtifacts(), true, Map.of("linux/amd64", List.of(updater))));
            campaignId = campaign.id();
            assertEquals(3L, campaign.summary().get("eligible"));
            assertEquals(1L, campaign.summary().get("deferred"));
            assertEquals(0, upgradeTarget(campaign, offline.machineId()).attempts());
            var poll = new PollRequest(List.of(), 1, List.of("command"));
            var firstPlan = service.offer(first.machineId(), poll);
            assertNotNull(firstPlan);
            assertNull(service.offer(flaky.machineId(), poll));
            upgradeHeartbeat(registry, first, prefix + "-a", "v2.0.0");
            service.updateStatus(first.machineId(), new UpgradeStatusRequest(campaign.id(), UpgradeService.COMPLETED,
                    null, firstPlan.attempt(), Map.of("agent-updater", "completed")));

            var plan = service.offer(flaky.machineId(), poll);
            for (int attempt = 1; attempt <= 3; attempt++) {
                assertEquals(attempt, plan.attempt());
                var failedAt = Instant.now();
                var result = service.updateStatus(flaky.machineId(), new UpgradeStatusRequest(campaign.id(),
                        UpgradeService.FAILED, "download HTTP connect timed out", plan.attempt(),
                        attempt == 1 ? Map.of("agent-updater", "already-current") : Map.of()));
                assertEquals(UpgradeService.RUNNING, result.status());
                var target = upgradeTarget(result, flaky.machineId());
                assertEquals("already-current", target.componentStatuses().get("agent-updater"));
                if (attempt == 3) {
                    assertEquals(UpgradeService.FAILED, target.status());
                    assertNull(target.retryAt());
                    break;
                }
                assertEquals(UpgradeService.RETRYING, target.status());
                assertTrue(target.retryAt().isAfter(failedAt.plusSeconds(attempt == 1 ? 29 : 119)));
                // A replacement Center observes the same deadline and budget from PostgreSQL.
                service = postgresUpgrades(registry);
                assertNull(service.offer(flaky.machineId(), poll));
                jdbc.update("UPDATE rcm_upgrade_target SET lease_until = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE campaign_id = ? AND agent_id = ?",
                        campaign.id(), flaky.machineId());
                var allocator = service;
                try (var workers = Executors.newVirtualThreadPerTaskExecutor()) {
                    var start = new CountDownLatch(1);
                    var left = workers.submit(() -> { start.await(); return allocator.offer(flaky.machineId(), poll); });
                    var right = workers.submit(() -> { start.await(); return allocator.offer(flaky.machineId(), poll); });
                    start.countDown();
                    var a = left.get(); var b = right.get();
                    assertTrue((a == null) != (b == null), "concurrent polls must issue exactly one offer");
                    plan = a == null ? b : a;
                }
                assertTrue(plan.components().isEmpty(), "verified components must not be reinstalled on a retry");
                var stale = service.updateStatus(flaky.machineId(), new UpgradeStatusRequest(campaign.id(),
                        UpgradeService.COMPLETED, null, attempt, Map.of()));
                assertEquals(UpgradeService.OFFERED, upgradeTarget(stale, flaky.machineId()).status());
            }
            assertNull(service.offer(flaky.machineId(), poll), "the exhausted target must not receive a fourth automatic attempt");
            var thirdPlan = service.offer(third.machineId(), poll);
            assertNotNull(thirdPlan, "a later batch proceeds after the failed regular target settles");
            upgradeHeartbeat(registry, third, prefix + "-c", "v2.0.0");
            var finished = service.updateStatus(third.machineId(), new UpgradeStatusRequest(campaign.id(),
                    UpgradeService.COMPLETED, null, thirdPlan.attempt(), Map.of("agent-updater", "completed")));
            assertEquals(UpgradeService.FAILED, finished.status());
            assertEquals(2L, finished.summary().get("completed"));
            assertEquals(1L, finished.summary().get("failed"));
            assertEquals(1L, finished.summary().get("deferred"));
            assertEquals(Boolean.FALSE, finished.summary().get("fully_updated"));
            assertEquals(Set.of(flaky.machineId()), postgresUpgrades(registry).failedMachines("v2.0.0"));

            var other = service.create(new CreateUpgradeCampaignRequest("v3.0.0", 1, 1,
                    List.of(third.machineId()), upgradeArtifacts()));
            otherCampaignId = other.id();
            var currentService = service;
            assertThrows(IllegalArgumentException.class, () -> currentService.retryTarget(campaign.id(), flaky.machineId()),
                    "an operator retry must not create two simultaneous active campaigns");
        } finally {
            deleteUpgradeCampaign(otherCampaignId);
            deleteUpgradeCampaign(campaignId);
            ids.forEach(id -> jdbc.update("DELETE FROM rcm_agent WHERE agent_id = ?", id));
        }
    }

    @Test
    void allOfflineUpgradeIsDeferredAndDoesNotOccupyAnActiveCampaign() {
        var registry = AgentRegistry.forTest("upgrade-enroll", jdbc);
        var name = "upgrade-offline-" + UUID.randomUUID().toString().replace("-", "");
        var machine = registry.register(upgradeRegistration(name, "v1.0.0"), "upgrade-enroll");
        String campaignId = null;
        String catchupId = null;
        try {
            jdbc.update("UPDATE rcm_agent SET last_seen_at = CURRENT_TIMESTAMP - INTERVAL '2 minutes' WHERE agent_id = ?", machine.machineId());
            var service = postgresUpgrades(registry);
            var campaign = service.create(new CreateUpgradeCampaignRequest("v2.0.0", 1, 1,
                    List.of(machine.machineId()), upgradeArtifacts()));
            campaignId = campaign.id();
            assertEquals(UpgradeService.DEFERRED, campaign.status());
            assertEquals(0, campaign.activeLimit());
            assertEquals(0L, campaign.summary().get("eligible"));
            assertEquals(Boolean.FALSE, campaign.summary().get("fully_updated"));
            assertEquals(Boolean.FALSE, campaign.summary().get("canary_verified"));
            assertEquals(false, postgresUpgrades(registry).hasActiveCampaign());
            upgradeHeartbeat(registry, machine, name, "v1.0.0");
            var catchup = postgresUpgrades(registry).create(new CreateUpgradeCampaignRequest("v2.0.0", 1, 1,
                    List.of(machine.machineId()), upgradeArtifacts()));
            catchupId = catchup.id();
            var plan = service.offer(machine.machineId(), new PollRequest(List.of(), 1, List.of("command")));
            assertNotNull(plan);
            var verifying = service.updateStatus(machine.machineId(), new UpgradeStatusRequest(catchup.id(),
                    UpgradeService.COMPLETED, null, plan.attempt(), Map.of()));
            assertEquals(UpgradeService.VERIFYING, verifying.targets().getFirst().status());
            jdbc.update("UPDATE rcm_upgrade_target SET lease_until = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE campaign_id = ?", catchup.id());
            postgresUpgrades(registry).reconcileActive();
            var failed = service.list(0, 100).stream().filter(row -> row.id().equals(catchup.id())).findFirst().orElseThrow();
            assertEquals(UpgradeService.PAUSED, failed.status());
            assertTrue(failed.targets().getFirst().error().contains("Agent version does not match"));
            assertEquals(UpgradeService.DEFERRED, service.list(0, 100).stream().filter(row -> row.id().equals(campaign.id())).findFirst().orElseThrow().status(),
                    "a historical deferred round is immutable when a new catch-up round starts");
        } finally {
            deleteUpgradeCampaign(catchupId);
            deleteUpgradeCampaign(campaignId);
            jdbc.update("DELETE FROM rcm_agent WHERE agent_id = ?", machine.machineId());
        }
    }

    @Test
    void disconnectBeforeDispatchReleasesCanarySlotAndReconnectDoesNotBypassValidation() {
        var registry = AgentRegistry.forTest("upgrade-enroll", jdbc);
        var prefix = "upgrade-slot-" + UUID.randomUUID().toString().replace("-", "");
        var first = registry.register(upgradeRegistration(prefix + "-a", "v1.0.0"), "upgrade-enroll");
        var second = registry.register(upgradeRegistration(prefix + "-b", "v1.0.0"), "upgrade-enroll");
        var third = registry.register(upgradeRegistration(prefix + "-c", "v1.0.0"), "upgrade-enroll");
        String campaignId = null;
        try {
            var service = postgresUpgrades(registry);
            var campaign = service.create(new CreateUpgradeCampaignRequest("v2.0.0", 1, 1,
                    List.of(first.machineId(), second.machineId(), third.machineId()), upgradeArtifacts()));
            campaignId = campaign.id();
            jdbc.update("UPDATE rcm_agent SET last_seen_at = CURRENT_TIMESTAMP - INTERVAL '2 minutes' WHERE agent_id = ?", first.machineId());
            var poll = new PollRequest(List.of(), 1, List.of("command"));
            var secondPlan = service.offer(second.machineId(), poll);
            assertNotNull(secondPlan, "an offline, undispatched canary must not occupy the slot");
            var deferred = upgradeTarget(service.list(0, 100).getFirst(), first.machineId());
            assertEquals(UpgradeService.DEFERRED, deferred.status());
            assertEquals(0, deferred.attempts());
            assertNull(service.offer(third.machineId(), poll));
            upgradeHeartbeat(registry, second, prefix + "-b", "v2.0.0");
            service.updateStatus(second.machineId(), new UpgradeStatusRequest(campaign.id(), UpgradeService.COMPLETED,
                    null, secondPlan.attempt(), Map.of()));
            upgradeHeartbeat(registry, first, prefix + "-a", "v1.0.0");
            assertNull(service.offer(third.machineId(), poll), "a returning first target must be verified before admitting the next batch");
            var firstPlan = service.offer(first.machineId(), poll);
            assertNotNull(firstPlan);
            upgradeHeartbeat(registry, first, prefix + "-a", "v2.0.0");
            service.updateStatus(first.machineId(), new UpgradeStatusRequest(campaign.id(), UpgradeService.COMPLETED,
                    null, firstPlan.attempt(), Map.of()));
            assertNotNull(service.offer(third.machineId(), poll));
        } finally {
            deleteUpgradeCampaign(campaignId);
            List.of(first, second, third).forEach(machine -> jdbc.update("DELETE FROM rcm_agent WHERE agent_id = ?", machine.machineId()));
        }
    }

    private UpgradeService postgresUpgrades(AgentRegistry registry) {
        var beans = new StaticListableBeanFactory();
        beans.addBean("jdbc", jdbc); beans.addBean("transactions", transactions);
        return new UpgradeService(registry, new TaskService(registry), new UpgradeConfig(true, ""),
                beans.getBeanProvider(JdbcTemplate.class), beans.getBeanProvider(TransactionTemplate.class),
                beans.getBeanProvider(TaskChangeRegistry.class), beans.getBeanProvider(AgentWakeRegistry.class),
                beans.getBeanProvider(AuditService.class), beans.getBeanProvider(ReleaseManifestService.class));
    }

    private static RegisterRequest upgradeRegistration(String name, String version) {
        return new RegisterRequest(name, name, name, "linux", "amd64", version, "/", List.of("command", "durable_tasks"));
    }

    private static Map<String, UpgradeArtifact> upgradeArtifacts() {
        return Map.of("linux/amd64", new UpgradeArtifact("linux", "amd64", "https://example.test/agent.zip", "a".repeat(64)));
    }

    private static void upgradeHeartbeat(AgentRegistry registry, RegisterResponse machine, String name, String version) {
        registry.poll(machine.machineId(), machine.token(), new PollRequest(List.of(), 1, List.of("command"), upgradeRegistration(name, version).metadata()));
    }

    private static UpgradeTargetView upgradeTarget(UpgradeCampaignView campaign, String id) {
        return campaign.targets().stream().filter(target -> target.machineId().equals(id)).findFirst().orElseThrow();
    }

    private void deleteUpgradeCampaign(String id) {
        if (id == null) return;
        jdbc.update("DELETE FROM rcm_upgrade_target WHERE campaign_id = ?", id);
        jdbc.update("DELETE FROM rcm_upgrade_campaign WHERE campaign_id = ?", id);
    }

    private static String required(String name) {
        var value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required for the PostgreSQL integration test");
        }
        return value.trim();
    }

    private static String sha256(byte[] data) {
        try {
            return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (java.security.NoSuchAlgorithmException exception) {
            throw new AssertionError(exception);
        }
    }
}
