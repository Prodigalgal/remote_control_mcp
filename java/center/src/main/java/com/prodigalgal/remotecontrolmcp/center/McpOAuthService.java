package com.prodigalgal.remotecontrolmcp.center;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.prodigalgal.remotecontrolmcp.protocol.JsonCodec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Small OAuth 2.1 authorization-code provider for MCP connections.
 *
 * <p>The authorization page accepts an already-issued Console MCP credential as the
 * bootstrap credential. It exchanges it for a short-lived OAuth access token
 * and a refresh token. PostgreSQL is authoritative in production and
 * the bounded maps keep protocol tests deterministic in memory mode.</p>
 */
@Service
public final class McpOAuthService {
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final int MAX_TOKEN_BYTES = 1024;

    private final CenterOAuthConfig config;
    private final McpPrincipalService principals;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transactions;
    private final Map<String, AuthorizationCode> codes = new ConcurrentHashMap<>();
    private final Map<String, OAuthToken> accessTokens = new ConcurrentHashMap<>();
    private final Map<String, OAuthToken> refreshTokens = new ConcurrentHashMap<>();

    @org.springframework.beans.factory.annotation.Autowired
    public McpOAuthService(CenterOAuthConfig config, McpPrincipalService principals,
                           ObjectProvider<JdbcTemplate> jdbcProvider,
                           ObjectProvider<TransactionTemplate> transactionProvider) {
        this.config = config;
        this.principals = principals;
        this.jdbc = jdbcProvider == null ? null : jdbcProvider.getIfAvailable();
        this.transactions = transactionProvider == null ? null : transactionProvider.getIfAvailable();
    }

    McpOAuthService(CenterOAuthConfig config, McpPrincipalService principals) {
        this.config = config;
        this.principals = principals;
        this.jdbc = null;
        this.transactions = null;
    }

    /** Resolve an OAuth access token to the same principal model as opaque RCM tokens. */
    public Optional<McpPrincipal> resolve(String candidate) {
        var value = normalize(candidate);
        if (value.isEmpty()) return Optional.empty();
        var hash = sha256(value);
        var memory = accessTokens.get(hash);
        if (memory != null) {
            if (memory.revokedAt() == null && Instant.now().isBefore(memory.expiresAt())
                    && principals.isTokenActive(memory.sourceTokenId())) {
                return Optional.of(memory.principal());
            }
            return Optional.empty();
        }
        if (jdbc == null) return Optional.empty();
        try {
            return jdbc.query("""
                    SELECT t.source_token_id, t.principal_id, COALESCE(t.display_name, p.display_name) AS display_name,
                           t.scope_json, t.expires_at
                      FROM rcm_oauth_access_token t
                      JOIN rcm_principal p ON p.principal_id = t.principal_id
                      JOIN rcm_mcp_token source ON source.token_id = t.source_token_id
                     WHERE t.token_hash = ? AND t.revoked_at IS NULL AND p.status = 'active'
                       AND source.revoked_at IS NULL
                       AND (source.expires_at IS NULL OR source.expires_at > CURRENT_TIMESTAMP)
                       AND t.expires_at > CURRENT_TIMESTAMP AND t.resource = ?
                     LIMIT 1
                    """, ps -> { ps.setString(1, hash); ps.setString(2, config.resource()); }, (rs, row) -> new McpPrincipal(
                    rs.getString("principal_id"), rs.getString("source_token_id"), rs.getString("display_name"),
                    parseScopes(rs.getString("scope_json")), false, rs.getTimestamp("expires_at").toInstant()))
                    .stream().findFirst();
        } catch (DataAccessException | NullPointerException ignored) {
            return Optional.empty();
        }
    }

    public AuthorizationCode issueAuthorizationCode(String clientId, String redirectUri,
                                                     String codeChallenge, String codeChallengeMethod,
                                                     String requestedScope, String resource,
                                                     String bootstrapToken) {
        ensureEnabled();
        validateClient(clientId, redirectUri, codeChallenge, codeChallengeMethod, resource);
        if (!config.allowStaticTokenBootstrap()) throw new SecurityException("RCM token bootstrap is disabled");
        var principal = principals.resolve(bootstrapToken)
                .orElseThrow(() -> new SecurityException("invalid RCM bootstrap token"));
        var scopes = requestedScopes(requestedScope, principal);
        var plaintext = "rcm_code_" + randomToken();
        var created = Instant.now();
        var value = new AuthorizationCode(sha256(plaintext), clientId, redirectUri, codeChallenge,
                principal.principalId(), principal.tokenId(), principal.displayName(), scopes, created,
                created.plus(config.authorizationCodeTtl()));
        if (jdbc != null && transactions != null) {
            transactions.executeWithoutResult(status -> jdbc.update("""
                    INSERT INTO rcm_oauth_authorization_code
                        (code_hash, client_id, redirect_uri, code_challenge, code_challenge_method,
                         principal_id, source_token_id, display_name, scope_json, resource, created_at, expires_at, consumed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS jsonb), ?, ?, ?, NULL)
                    """, value.codeHash(), value.clientId(), value.redirectUri(), value.codeChallenge(),
                    "S256", value.principalId(), value.sourceTokenId(), value.displayName(), json(value.scopes()), config.resource(),
                    timestamp(value.createdAt()), timestamp(value.expiresAt())));
        } else {
            codes.put(value.codeHash(), value);
        }
        return new AuthorizationCode(plaintext, value.clientId(), value.redirectUri(), value.codeChallenge(),
                value.principalId(), value.sourceTokenId(), value.displayName(), value.scopes(), value.createdAt(), value.expiresAt());
    }

    public TokenResponse exchangeAuthorizationCode(String clientId, String redirectUri,
                                                    String code, String codeVerifier, String resource) {
        ensureEnabled();
        if (!config.validClientRedirect(clientId, redirectUri) || code == null || code.isBlank()
                || codeVerifier == null || codeVerifier.isBlank() || !config.validResource(resource)) {
            throw new OAuthException("invalid_grant", "authorization code is invalid");
        }
        var hash = sha256(code);
        var stored = loadCode(hash).orElseThrow(() -> new OAuthException("invalid_grant", "authorization code is invalid"));
        if (!clientId.equals(stored.clientId()) || !redirectUri.equals(stored.redirectUri())
                || !Instant.now().isBefore(stored.expiresAt()) || !pkceMatches(codeVerifier, stored.codeChallenge())) {
            throw new OAuthException("invalid_grant", "authorization code is invalid");
        }
        if (jdbc != null && transactions != null) {
            var issued = transactions.execute(status -> {
                var consumed = jdbc.update("""
                        UPDATE rcm_oauth_authorization_code
                           SET consumed_at = CURRENT_TIMESTAMP
                         WHERE code_hash = ? AND consumed_at IS NULL AND expires_at > CURRENT_TIMESTAMP
                        """, hash);
                if (consumed != 1) throw new OAuthException("invalid_grant", "authorization code was already used");
                return issueDatabaseTokens(stored);
            });
            return issued == null ? throwInvalidGrant() : issued;
        }
        var removed = codes.remove(hash);
        if (removed == null || !Instant.now().isBefore(removed.expiresAt())) {
            throw new OAuthException("invalid_grant", "authorization code was already used");
        }
        return issueMemoryTokens(removed);
    }

    public TokenResponse refresh(String clientId, String refreshToken, String resource) {
        ensureEnabled();
        if (clientId == null || !config.validClientId(clientId) || !config.validResource(resource)) {
            throw new OAuthException("invalid_request", "client_id or resource is invalid");
        }
        var value = normalize(refreshToken);
        var hash = sha256(value);
        if (jdbc != null && transactions != null) {
            var stored = loadRefresh(hash).orElseThrow(() -> new OAuthException("invalid_grant", "refresh token is invalid"));
            if (!clientId.equals(stored.clientId()) || !Instant.now().isBefore(stored.expiresAt())) {
                throw new OAuthException("invalid_grant", "refresh token is invalid");
            }
            return transactions.execute(status -> {
                if (config.isGeminiClient(clientId)) {
                    ensureSourceTokenActive(stored.sourceTokenId());
                    var updated = jdbc.update("""
                            UPDATE rcm_oauth_refresh_token
                               SET expires_at = GREATEST(expires_at, ?)
                             WHERE token_hash = ? AND client_id = ? AND revoked_at IS NULL
                               AND expires_at > CURRENT_TIMESTAMP
                            """, timestamp(Instant.now().plus(config.refreshTokenTtl())), hash, clientId);
                    if (updated != 1) throw new OAuthException("invalid_grant", "refresh token is invalid");
                    return issueDatabaseAccessToken(stored, value);
                }
                var revoked = jdbc.update("""
                        UPDATE rcm_oauth_refresh_token
                           SET revoked_at = CURRENT_TIMESTAMP
                         WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > CURRENT_TIMESTAMP
                        """, hash);
                if (revoked != 1) throw new OAuthException("invalid_grant", "refresh token was already used");
                return issueDatabaseTokens(stored);
            });
        }
        var source = new java.util.concurrent.atomic.AtomicReference<OAuthToken>();
        refreshTokens.compute(hash, (key, stored) -> {
            if (stored == null || !clientId.equals(stored.clientId()) || !Instant.now().isBefore(stored.expiresAt())) {
                throw new OAuthException("invalid_grant", "refresh token is invalid");
            }
            ensureSourceTokenActive(stored.sourceTokenId());
            source.set(stored);
            if (!config.isGeminiClient(clientId)) return null;
            var expiry = Instant.now().plus(config.refreshTokenTtl());
            if (stored.expiresAt().isAfter(expiry)) expiry = stored.expiresAt();
            return new OAuthToken(stored.token(), stored.clientId(), stored.principalId(), stored.sourceTokenId(),
                    stored.displayName(), stored.scopes(), stored.createdAt(), expiry, null, stored.principal());
        });
        return config.isGeminiClient(clientId)
                ? issueMemoryAccessToken(source.get(), value) : issueMemoryTokens(source.get());
    }

    public boolean isEnabledAndConfigured() {
        return config.enabled() && config.isConfigured();
    }

    private TokenResponse issueDatabaseTokens(AuthorizationCode code) {
        return issueDatabaseTokens(new OAuthToken("", code.clientId(), code.principalId(), code.sourceTokenId(), code.displayName(),
                code.scopes(), Instant.now(), Instant.now().plus(config.refreshTokenTtl()), null));
    }

    private TokenResponse issueDatabaseTokens(OAuthToken source) {
        ensureSourceTokenActive(source.sourceTokenId());
        var refresh = "rcm_rt_" + randomToken();
        var now = Instant.now();
        var refreshExpiry = now.plus(config.refreshTokenTtl());
        jdbc.update("""
                INSERT INTO rcm_oauth_refresh_token
                    (token_id, token_hash, principal_id, source_token_id, display_name, client_id, scope_json, resource,
                     created_at, expires_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, CAST(? AS jsonb), ?, ?, ?, NULL)
                """, "oauth_rt_" + randomHex(16), sha256(refresh), source.principalId(), source.sourceTokenId(), source.displayName(),
                source.clientId(), json(source.scopes()), config.resource(), timestamp(now), timestamp(refreshExpiry));
        return issueDatabaseAccessToken(source, refresh);
    }

    private TokenResponse issueDatabaseAccessToken(OAuthToken source, String refresh) {
        ensureSourceTokenActive(source.sourceTokenId());
        var access = "rcm_at_" + randomToken();
        var now = Instant.now();
        var accessExpiry = now.plus(config.accessTokenTtl());
        jdbc.update("""
                INSERT INTO rcm_oauth_access_token
                    (token_id, token_hash, principal_id, source_token_id, display_name, client_id, scope_json, resource,
                     created_at, expires_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, CAST(? AS jsonb), ?, ?, ?, NULL)
                """, "oauth_at_" + randomHex(16), sha256(access), source.principalId(), source.sourceTokenId(), source.displayName(),
                source.clientId(), json(source.scopes()), config.resource(), timestamp(now), timestamp(accessExpiry));
        return response(access, refresh, accessExpiry, source.scopes(), source.clientId());
    }

    private TokenResponse issueMemoryTokens(AuthorizationCode code) {
        return issueMemoryTokens(new OAuthToken("", code.clientId(), code.principalId(), code.sourceTokenId(), code.displayName(),
                code.scopes(), Instant.now(), Instant.now().plus(config.refreshTokenTtl()), null));
    }

    private TokenResponse issueMemoryTokens(OAuthToken source) {
        ensureSourceTokenActive(source.sourceTokenId());
        var refresh = "rcm_rt_" + randomToken();
        var now = Instant.now();
        var refreshExpiry = now.plus(config.refreshTokenTtl());
        refreshTokens.put(sha256(refresh), new OAuthToken("", source.clientId(), source.principalId(),
                source.sourceTokenId(), source.displayName(), source.scopes(), now, refreshExpiry, null));
        return issueMemoryAccessToken(source, refresh);
    }

    private TokenResponse issueMemoryAccessToken(OAuthToken source, String refresh) {
        ensureSourceTokenActive(source.sourceTokenId());
        var access = "rcm_at_" + randomToken();
        var now = Instant.now();
        var accessExpiry = now.plus(config.accessTokenTtl());
        var principal = new McpPrincipal(source.principalId(), source.sourceTokenId(),
                source.displayName(), source.scopes(), false, accessExpiry);
        accessTokens.put(sha256(access), new OAuthToken("", source.clientId(), source.principalId(),
                source.sourceTokenId(), source.displayName(), source.scopes(), now, accessExpiry, null, principal));
        return response(access, refresh, accessExpiry, source.scopes(), source.clientId());
    }

    private void ensureSourceTokenActive(String sourceTokenId) {
        if (sourceTokenId == null || sourceTokenId.isBlank() || !principals.isTokenActive(sourceTokenId)) {
            throw new OAuthException("invalid_grant", "source Console credential is no longer active");
        }
    }

    private Optional<AuthorizationCode> loadCode(String hash) {
        var value = codes.get(hash);
        if (value != null) return Optional.of(value);
        if (jdbc == null) return Optional.empty();
        try {
            return jdbc.query("""
                    SELECT code_hash, client_id, redirect_uri, code_challenge, principal_id, source_token_id, display_name,
                           scope_json, created_at, expires_at
                      FROM rcm_oauth_authorization_code
                     WHERE code_hash = ? AND consumed_at IS NULL AND expires_at > CURRENT_TIMESTAMP
                    """, ps -> ps.setString(1, hash), (rs, row) -> new AuthorizationCode(
                    rs.getString("code_hash"), rs.getString("client_id"), rs.getString("redirect_uri"),
                    rs.getString("code_challenge"), rs.getString("principal_id"), rs.getString("source_token_id"), rs.getString("display_name"),
                    parseScopes(rs.getString("scope_json")), rs.getTimestamp("created_at").toInstant(),
                    rs.getTimestamp("expires_at").toInstant())).stream().findFirst();
        } catch (DataAccessException | NullPointerException ignored) {
            return Optional.empty();
        }
    }

    private Optional<OAuthToken> loadRefresh(String hash) {
        if (jdbc == null) return Optional.empty();
        try {
            return jdbc.query("""
                    SELECT t.token_hash, t.client_id, t.principal_id, t.source_token_id, t.display_name, t.scope_json, t.expires_at
                      FROM rcm_oauth_refresh_token t
                      JOIN rcm_principal p ON p.principal_id = t.principal_id
                      JOIN rcm_mcp_token source ON source.token_id = t.source_token_id
                     WHERE t.token_hash = ? AND t.revoked_at IS NULL AND p.status = 'active'
                       AND source.revoked_at IS NULL
                       AND (source.expires_at IS NULL OR source.expires_at > CURRENT_TIMESTAMP)
                       AND t.expires_at > CURRENT_TIMESTAMP AND t.resource = ?
                    """, ps -> { ps.setString(1, hash); ps.setString(2, config.resource()); }, (rs, row) -> new OAuthToken(
                    rs.getString("token_hash"), rs.getString("client_id"), rs.getString("principal_id"), rs.getString("source_token_id"),
                    rs.getString("display_name"), parseScopes(rs.getString("scope_json")), Instant.now(),
                    rs.getTimestamp("expires_at").toInstant(), null)).stream().findFirst();
        } catch (DataAccessException | NullPointerException ignored) {
            return Optional.empty();
        }
    }

    private void validateClient(String clientId, String redirectUri, String codeChallenge,
                                String codeChallengeMethod, String resource) {
        if (!config.validClientRedirect(clientId, redirectUri)
                || codeChallenge == null || codeChallenge.isBlank()
                || !"S256".equalsIgnoreCase(codeChallengeMethod) || !config.validResource(resource)) {
            throw new OAuthException("invalid_request", "OAuth client, redirect URI, resource or PKCE is invalid");
        }
    }

    private Set<String> requestedScopes(String raw, McpPrincipal principal) {
        var requested = raw == null || raw.isBlank() ? config.scopes() : splitScopes(raw);
        if (requested.isEmpty()) {
            throw new OAuthException("invalid_scope", "no OAuth scopes were requested");
        }
        if (requested.stream().anyMatch(scope -> !"offline_access".equals(scope) && !config.scopes().contains(scope))) {
            throw new OAuthException("invalid_scope", "requested scope is not supported");
        }
        // Scope metadata describes what this server can do, not what every
        // bootstrap credential grants. Grant only the intersection so a
        // broad advertised scope cannot make a narrower valid token unusable.
        // offline_access is a protocol capability, not an RCM permission.
        var granted = requested.stream()
                .filter(scope -> "offline_access".equals(scope) || principal.allows(scope))
                .collect(java.util.stream.Collectors.toUnmodifiableSet());
        if (granted.isEmpty()) {
            throw new OAuthException("invalid_scope", "no requested scope is granted to this principal");
        }
        return granted;
    }

    private void ensureEnabled() {
        if (!isEnabledAndConfigured()) throw new OAuthException("temporarily_unavailable", "OAuth is not configured");
    }

    private static boolean pkceMatches(String verifier, String challenge) {
        try {
            var digest = MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII));
            return MessageDigest.isEqual(Base64.getUrlEncoder().withoutPadding().encode(digest),
                    challenge.getBytes(StandardCharsets.US_ASCII));
        } catch (java.security.NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private static Set<String> splitScopes(String raw) {
        var values = new LinkedHashSet<String>();
        for (var value : raw.trim().split("[ \\t\\r\\n]+")) {
            if (!value.isBlank()) values.add(value.trim().toLowerCase(java.util.Locale.ROOT));
        }
        return Set.copyOf(values);
    }

    private static String normalize(String value) {
        if (value == null || value.isBlank()) return "";
        var normalized = value.trim();
        if (normalized.length() > MAX_TOKEN_BYTES || normalized.chars().anyMatch(Character::isISOControl)) return "";
        return normalized;
    }

    private static String randomToken() {
        var bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private static String randomHex(int bytes) {
        var value = new byte[bytes];
        RANDOM.nextBytes(value);
        return java.util.HexFormat.of().formatHex(value);
    }

    private static String sha256(String value) {
        try {
            return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (java.security.NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private static String json(Set<String> values) {
        return new String(JsonCodec.write(values), StandardCharsets.UTF_8);
    }

    private static Set<String> parseScopes(String json) {
        if (json == null || json.isBlank()) return Set.of("mcp:read");
        try {
            var values = JsonCodec.read(json.getBytes(StandardCharsets.UTF_8), List.class);
            var result = new LinkedHashSet<String>();
            for (var value : values) if (value != null) result.add(String.valueOf(value));
            return result.isEmpty() ? Set.of("mcp:read") : Set.copyOf(result);
        } catch (RuntimeException ignored) {
            return Set.of("mcp:read");
        }
    }

    private static java.sql.Timestamp timestamp(Instant value) {
        return value == null ? null : java.sql.Timestamp.from(value);
    }

    private TokenResponse response(String access, String refresh, Instant expiry, Set<String> scopes, String clientId) {
        return new TokenResponse(access, config.isGeminiClient(clientId) ? "bearer" : "Bearer",
                Math.max(1, expiry.getEpochSecond() - Instant.now().getEpochSecond()),
                refresh, String.join(" ", scopes));
    }

    private static TokenResponse throwInvalidGrant() {
        throw new OAuthException("invalid_grant", "authorization code was already used");
    }

    public record AuthorizationCode(String code, String clientId, String redirectUri, String codeChallenge,
                                    String principalId, String sourceTokenId, String displayName, Set<String> scopes,
                                    Instant createdAt, Instant expiresAt) {
        public String codeHash() { return code; }
    }

    private record OAuthToken(String token, String clientId, String principalId, String sourceTokenId, String displayName,
                              Set<String> scopes, Instant createdAt, Instant expiresAt, Instant revokedAt,
                              McpPrincipal principal) {
        private OAuthToken(String token, String clientId, String principalId, String sourceTokenId, String displayName,
                           Set<String> scopes, Instant createdAt, Instant expiresAt, Instant revokedAt) {
            this(token, clientId, principalId, sourceTokenId, displayName, scopes, createdAt, expiresAt, revokedAt, null);
        }
    }

    public record TokenResponse(@JsonProperty("access_token") String accessToken,
                                @JsonProperty("token_type") String tokenType,
                                @JsonProperty("expires_in") long expiresIn,
                                @JsonProperty("refresh_token") String refreshToken,
                                String scope) {
    }

    public static final class OAuthException extends RuntimeException {
        private final String error;

        public OAuthException(String error, String message) {
            super(message);
            this.error = error;
        }

        public String error() {
            return error;
        }
    }
}
