package com.prodigalgal.remotecontrolmcp.center;

import com.prodigalgal.remotecontrolmcp.protocol.RuntimeEnvironment;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.Arrays;
import java.util.Locale;
import java.util.Set;
import java.util.stream.Collectors;
import org.springframework.stereotype.Component;

/**
 * Runtime OAuth configuration for the MCP resource.
 *
 * <p>OAuth is deliberately opt-in.  The Center can therefore keep serving
 * existing Console-issued Bearer clients while a deployment rolls out the
 * OAuth metadata and republishes the ChatGPT app. Once enabled, model-facing
 * tools advertise OAuth; direct clients may still use their own Console-issued
 * credential, and no process-wide MCP Bearer secret is used.</p>
 */
@Component
public final class CenterOAuthConfig {
    private static final Set<String> DEFAULT_SCOPES = Set.of("mcp:read", "mcp:execute");

    private final boolean enabled;
    private final boolean allowStaticTokenBootstrap;
    private final String issuer;
    private final String resource;
    private final Duration authorizationCodeTtl;
    private final Duration accessTokenTtl;
    private final Duration refreshTokenTtl;
    private final Set<String> scopes;
    private final String geminiClientId;
    private final String geminiClientSecret;
    private final Set<String> geminiRedirectUris;

    public CenterOAuthConfig() {
        this(RuntimeEnvironment.snapshot());
    }

    CenterOAuthConfig(java.util.Map<String, String> environment) {
        this.enabled = booleanSetting(environment, "RCM_CENTER_OAUTH_ENABLED", false);
        var publicBase = normalizeBase(environment.getOrDefault("RCM_CENTER_PUBLIC_BASE_URL", ""));
        this.issuer = normalizeBase(environment.getOrDefault("RCM_CENTER_OAUTH_ISSUER", publicBase));
        this.resource = normalizeBase(environment.getOrDefault("RCM_CENTER_OAUTH_RESOURCE", publicBase));
        this.allowStaticTokenBootstrap = booleanSetting(environment,
                "RCM_CENTER_OAUTH_ALLOW_STATIC_TOKEN_BOOTSTRAP", true);
        this.authorizationCodeTtl = boundedSeconds(environment, "RCM_CENTER_OAUTH_AUTHORIZATION_CODE_TTL_SECONDS", 180, 30, 600);
        this.accessTokenTtl = boundedSeconds(environment, "RCM_CENTER_OAUTH_ACCESS_TOKEN_TTL_SECONDS", 3600, 300, 86400);
        this.refreshTokenTtl = boundedSeconds(environment, "RCM_CENTER_OAUTH_REFRESH_TOKEN_TTL_SECONDS", 2592000, 3600, 315360000);
        this.scopes = parseScopes(environment.get("RCM_CENTER_OAUTH_SCOPES"));
        this.geminiClientId = environment.getOrDefault("RCM_CENTER_OAUTH_GEMINI_CLIENT_ID", "");
        this.geminiClientSecret = environment.getOrDefault("RCM_CENTER_OAUTH_GEMINI_CLIENT_SECRET", "");
        this.geminiRedirectUris = parseGeminiRedirectUris(environment.get("RCM_CENTER_OAUTH_GEMINI_REDIRECT_URIS"));
        if (!geminiClientId.isEmpty() || !geminiClientSecret.isEmpty() || !geminiRedirectUris.isEmpty()) {
            if (!validCredential(geminiClientId) || geminiClientId.length() > 512 || !validCredential(geminiClientSecret)
                    || isChatGptClientId(geminiClientId) || geminiRedirectUris.isEmpty()) {
                throw new IllegalArgumentException("Gemini OAuth requires a client ID, client secret, and exact Google redirect URIs");
            }
        }
    }

    public boolean enabled() {
        return enabled;
    }

    public boolean allowStaticTokenBootstrap() {
        return allowStaticTokenBootstrap;
    }

    public String issuer() {
        return issuer;
    }

    public String resource() {
        return resource;
    }

    public String protectedResourceMetadataUrl() {
        var uri = URI.create(mcpResource());
        return uri.getScheme() + "://" + uri.getRawAuthority()
                + "/.well-known/oauth-protected-resource" + uri.getRawPath();
    }

    public String mcpResource() {
        return resource.isEmpty() || resource.endsWith("/mcp") ? resource : resource + "/mcp";
    }

    public String authorizationServerMetadataUrl() {
        return issuer + "/.well-known/oauth-authorization-server";
    }

    public String authorizationEndpoint() {
        return issuer + "/oauth/authorize";
    }

    public String tokenEndpoint() {
        return issuer + "/oauth/token";
    }

    public Duration authorizationCodeTtl() {
        return authorizationCodeTtl;
    }

    public Duration accessTokenTtl() {
        return accessTokenTtl;
    }

    public Duration refreshTokenTtl() {
        return refreshTokenTtl;
    }

    public Set<String> scopes() {
        return scopes;
    }

    public boolean isConfigured() {
        return enabled && httpsUrl(issuer) && httpsUrl(resource);
    }

    public boolean validResource(String candidate) {
        return candidate == null || candidate.isBlank() || resource.equals(normalizeBase(candidate))
                || mcpResource().equals(normalizeBase(candidate));
    }

    public boolean validClientId(String clientId) {
        return isGeminiClient(clientId) || isChatGptClientId(clientId);
    }

    public boolean isGeminiClient(String clientId) {
        return clientId != null && !geminiClientId.isEmpty() && geminiClientId.equals(clientId);
    }

    public boolean validClientRedirect(String clientId, String redirectUri) {
        if (isGeminiClient(clientId)) return redirectUri != null && geminiRedirectUris.contains(redirectUri);
        return isChatGptClientId(clientId) && validChatGptRedirect(redirectUri);
    }

    public boolean authenticateClient(String clientId, String clientSecret) {
        if (isGeminiClient(clientId)) {
            return clientSecret != null && MessageDigest.isEqual(
                    geminiClientSecret.getBytes(StandardCharsets.UTF_8), clientSecret.getBytes(StandardCharsets.UTF_8));
        }
        return isChatGptClientId(clientId) && (clientSecret == null || clientSecret.isEmpty());
    }

    public boolean geminiConfigured() {
        return !geminiClientId.isEmpty();
    }

    private static boolean isChatGptClientId(String clientId) {
        if (clientId == null || clientId.isBlank()) return false;
        try {
            var uri = URI.create(clientId);
            return "https".equalsIgnoreCase(uri.getScheme())
                    && "chatgpt.com".equalsIgnoreCase(uri.getHost())
                    && uri.getRawUserInfo() == null
                    && uri.getRawFragment() == null;
        } catch (IllegalArgumentException ignored) {
            return false;
        }
    }

    public boolean validRedirectUri(String redirectUri) {
        return redirectUri != null && (geminiRedirectUris.contains(redirectUri) || validChatGptRedirect(redirectUri));
    }

    private static boolean validChatGptRedirect(String redirectUri) {
        if (redirectUri == null || redirectUri.isBlank()) return false;
        try {
            var uri = URI.create(redirectUri);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || !"chatgpt.com".equalsIgnoreCase(uri.getHost())
                    || uri.getRawUserInfo() != null || uri.getRawFragment() != null) return false;
            var path = uri.getPath() == null ? "" : uri.getPath();
            return "/connector_platform_oauth_redirect".equals(path)
                    || path.startsWith("/connector/oauth/");
        } catch (IllegalArgumentException ignored) {
            return false;
        }
    }

    private static Set<String> parseGeminiRedirectUris(String raw) {
        if (raw == null || raw.isBlank()) return Set.of();
        var uris = Arrays.stream(raw.split("[,\\s]+"))
                .filter(value -> !value.isBlank()).collect(Collectors.toUnmodifiableSet());
        if (uris.isEmpty() || uris.stream().anyMatch(value -> !validGoogleRedirect(value))) {
            throw new IllegalArgumentException("RCM_CENTER_OAUTH_GEMINI_REDIRECT_URIS must contain exact Google HTTPS callback URIs");
        }
        return uris;
    }

    private static boolean validGoogleRedirect(String value) {
        try {
            if (value.length() > 2048) return false;
            var uri = URI.create(value);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getRawUserInfo() != null
                    || uri.getPort() != -1 || uri.getRawQuery() != null || uri.getRawFragment() != null) return false;
            if ("vertexaisearch.cloud.google.com".equalsIgnoreCase(uri.getHost())) {
                return "/oauth-redirect".equals(uri.getRawPath());
            }
            if (!Set.of("oauth-redirect.googleusercontent.com", "oauth-redirect-sandbox.googleusercontent.com",
                    "oauth-redirect-test.googleusercontent.com").contains(uri.getHost())) return false;
            var path = uri.getRawPath();
            return path != null && path.length() > 3 && !path.contains("*")
                    && (path.startsWith("/r/") || path.startsWith("/a/"));
        } catch (IllegalArgumentException | NullPointerException ignored) {
            return false;
        }
    }

    private static boolean validCredential(String value) {
        return value != null && !value.isBlank() && value.length() <= 1024
                && value.equals(value.trim()) && value.chars().noneMatch(Character::isISOControl);
    }

    private static Duration boundedSeconds(java.util.Map<String, String> environment, String key,
                                           long fallback, long min, long max) {
        var raw = environment.getOrDefault(key, Long.toString(fallback));
        try {
            var seconds = Long.parseLong(raw == null || raw.isBlank() ? Long.toString(fallback) : raw.trim());
            if (seconds < min || seconds > max) throw new IllegalArgumentException(key + " must be between " + min + " and " + max);
            return Duration.ofSeconds(seconds);
        } catch (NumberFormatException exception) {
            throw new IllegalArgumentException(key + " must be an integer", exception);
        }
    }

    private static boolean booleanSetting(java.util.Map<String, String> environment, String key, boolean fallback) {
        var value = environment.get(key);
        return value == null || value.isBlank() ? fallback : Boolean.parseBoolean(value.trim());
    }

    private static Set<String> parseScopes(String raw) {
        if (raw == null || raw.isBlank()) return DEFAULT_SCOPES;
        var parsed = java.util.Arrays.stream(raw.split("[ ,\\t\\r\\n]+"))
                .map(String::trim).filter(value -> !value.isBlank()).map(value -> value.toLowerCase(Locale.ROOT))
                .collect(Collectors.toCollection(java.util.LinkedHashSet::new));
        if (parsed.isEmpty()) return DEFAULT_SCOPES;
        if (parsed.stream().anyMatch(value -> !value.matches("[a-z0-9:._-]{1,64}"))) {
            throw new IllegalArgumentException("RCM_CENTER_OAUTH_SCOPES contains an invalid scope");
        }
        return Set.copyOf(parsed);
    }

    private static String normalizeBase(String value) {
        if (value == null || value.isBlank()) return "";
        var normalized = value.trim();
        while (normalized.endsWith("/")) normalized = normalized.substring(0, normalized.length() - 1);
        return normalized;
    }

    private static boolean httpsUrl(String value) {
        if (value == null || value.isBlank()) return false;
        try {
            var uri = URI.create(value);
            return "https".equalsIgnoreCase(uri.getScheme()) && uri.getHost() != null
                    && uri.getRawQuery() == null && uri.getRawFragment() == null;
        } catch (IllegalArgumentException ignored) {
            return false;
        }
    }
}
