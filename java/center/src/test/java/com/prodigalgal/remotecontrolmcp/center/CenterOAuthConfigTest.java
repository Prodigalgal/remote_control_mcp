package com.prodigalgal.remotecontrolmcp.center;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Map;
import org.junit.jupiter.api.Test;

class CenterOAuthConfigTest {
    @Test
    void acceptsChatGptCimdAndStableRedirectOnlyWhenHttps() {
        var config = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_ENABLED", "true",
                "RCM_CENTER_PUBLIC_BASE_URL", "https://remote-control-mcp-center.example.com"));

        assertTrue(config.isConfigured());
        assertTrue(config.validClientId("https://chatgpt.com/oauth/client.json"));
        assertTrue(config.validRedirectUri("https://chatgpt.com/connector_platform_oauth_redirect"));
        assertTrue(config.validRedirectUri("https://chatgpt.com/connector/oauth/callback-123"));
        assertFalse(config.validClientId("http://chatgpt.com/oauth/client.json"));
        assertFalse(config.validRedirectUri("https://evil.example/redirect"));
    }

    @Test
    void disabledOrNonHttpsIssuerIsNotAdvertised() {
        var disabled = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_PUBLIC_BASE_URL", "https://remote-control-mcp-center.example.com"));
        var nonHttps = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_ENABLED", "true",
                "RCM_CENTER_OAUTH_ISSUER", "http://auth.example.com",
                "RCM_CENTER_OAUTH_RESOURCE", "https://resource.example.com"));

        assertFalse(disabled.isConfigured());
        assertFalse(nonHttps.isConfigured());
    }

    @Test
    void bindsConfiguredGeminiClientToExactOfficialCallbacks() {
        var config = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_ID", "gemini-test",
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_SECRET", "secret",
                "RCM_CENTER_OAUTH_GEMINI_REDIRECT_URIS",
                "https://oauth-redirect.googleusercontent.com/r/app-1,https://oauth-redirect-test.googleusercontent.com/a/app-1 https://vertexaisearch.cloud.google.com/oauth-redirect"));
        assertTrue(config.validClientRedirect("gemini-test", "https://oauth-redirect.googleusercontent.com/r/app-1"));
        assertTrue(config.validClientRedirect("gemini-test", "https://oauth-redirect-test.googleusercontent.com/a/app-1"));
        assertTrue(config.validClientRedirect("gemini-test", "https://vertexaisearch.cloud.google.com/oauth-redirect"));
        assertFalse(config.validClientRedirect("gemini-test", "https://oauth-redirect.googleusercontent.com/r/app-2"));
        assertFalse(config.validClientRedirect("gemini-test", "https://chatgpt.com/connector_platform_oauth_redirect"));
        assertFalse(config.validClientRedirect("https://chatgpt.com/oauth/client.json", "https://oauth-redirect.googleusercontent.com/r/app-1"));
        assertFalse(config.validClientRedirect("gemini-test", null));
        assertTrue(config.authenticateClient("gemini-test", "secret"));
        assertFalse(config.authenticateClient("gemini-test", "wrong"));
        assertFalse(config.authenticateClient("gemini-test", null));
    }

    @Test
    void rejectsIncompleteGeminiConfigurationAndUnsafeCallbacks() {
        assertThrows(IllegalArgumentException.class, () -> new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_ID", "gemini-test")));
        for (var redirect : new String[] {
                "https://oauth-redirect.googleusercontent.com/r/*",
                "http://oauth-redirect.googleusercontent.com/r/app",
                "https://oauth-redirect.googleusercontent.com.evil.example/r/app",
                "https://oauth-redirect.googleusercontent.com/r/app?next=evil",
                "https://oauth-redirect.googleusercontent.com/r/app#fragment",
                "https://evil.example/r/app"}) {
            assertThrows(IllegalArgumentException.class, () -> new CenterOAuthConfig(Map.of(
                    "RCM_CENTER_OAUTH_GEMINI_CLIENT_ID", "gemini-test",
                    "RCM_CENTER_OAUTH_GEMINI_CLIENT_SECRET", "secret",
                    "RCM_CENTER_OAUTH_GEMINI_REDIRECT_URIS", redirect)));
        }
    }

    @Test
    void advertisesTheMcpResourceAndRetainsTheConfiguredOriginAlias() {
        var config = new CenterOAuthConfig(Map.of("RCM_CENTER_OAUTH_ENABLED", "true",
                "RCM_CENTER_PUBLIC_BASE_URL", "https://center.example.com"));
        assertEquals("https://center.example.com/mcp", config.mcpResource());
        assertEquals("https://center.example.com/.well-known/oauth-protected-resource/mcp",
                config.protectedResourceMetadataUrl());
        assertTrue(config.validResource("https://center.example.com"));
        assertTrue(config.validResource("https://center.example.com/mcp"));
        assertFalse(config.validResource("https://center.example.com/other"));
        assertFalse(config.validResource("https://other.example.com/mcp"));
    }
}
