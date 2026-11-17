package com.prodigalgal.remotecontrolmcp.center;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import java.net.URI;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class McpOAuthControllerTest {
    private static final String CLIENT_ID = "https://chatgpt.com/oauth/client.json";
    private static final String RESOURCE = "https://remote-control-mcp-center.example.com";
    private static final String GEMINI_ID = "gemini client+id";
    private static final String GEMINI_SECRET = "secret+: value";
    private static final String GEMINI_REDIRECT = "https://oauth-redirect.googleusercontent.com/r/app-1";

    @ParameterizedTest
    @ValueSource(strings = {
            "https://chatgpt.com/connector_platform_oauth_redirect",
            "https://chatgpt.com/connector/oauth/callback-123?opaque=one;script-src=*"
    })
    void formPolicyAllowsTheValidatedCallbackOriginWithoutAcceptingQueryDirectives(String redirectUri) {
        var response = controller().authorizePage(CLIENT_ID, redirectUri, "code",
                "mcp:read", "state", "challenge", "S256", RESOURCE);

        assertEquals(200, response.getStatusCode().value());
        var page = (String) response.getBody();
        assertTrue(page.contains("content=\"default-src 'none'; style-src 'unsafe-inline'; "
                + "form-action 'self' https://chatgpt.com; base-uri 'none'\""));
        assertTrue(page.contains("<form method=\"post\" action=\"/oauth/authorize\">"));
        assertFalse(page.contains("<script"));
    }

    @Test
    void formPolicyPreservesAnExplicitValidatedCallbackPort() {
        var response = controller().authorizePage(CLIENT_ID,
                "https://chatgpt.com:443/connector_platform_oauth_redirect", "code",
                null, "state", "challenge", "S256", RESOURCE);

        assertEquals(200, response.getStatusCode().value());
        assertTrue(((String) response.getBody()).contains(
                "form-action 'self' https://chatgpt.com:443; base-uri 'none'"));
    }

    @Test
    void untrustedCallbackCannotReachTheConsentForm() {
        var response = controller().authorizePage(CLIENT_ID,
                "https://untrusted.example/connector_platform_oauth_redirect", "code",
                null, "state", "challenge", "S256", RESOURCE);

        assertEquals(400, response.getStatusCode().value());
        assertFalse(((String) response.getBody()).contains("<form"));
    }

    @Test
    void metadataAdvertisesOnlyImplementedCapabilities() {
        var body = (String) geminiController(new McpPrincipalService()).authorizationServerMetadata().getBody();
        assertTrue(body.contains("\"response_types_supported\":[\"code\"]"));
        assertTrue(body.contains("\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"]"));
        assertTrue(body.contains("\"code_challenge_methods_supported\":[\"S256\"]"));
        assertTrue(body.contains("\"token_endpoint_auth_methods_supported\":[\"none\",\"client_secret_basic\",\"client_secret_post\"]"));
        assertFalse(body.contains("registration_endpoint"));
        var protectedResource = (String) geminiController(new McpPrincipalService()).protectedResourceMetadata().getBody();
        assertTrue(protectedResource.contains("\"authorization_servers\":[\"" + RESOURCE + "\"]"));
        assertTrue(protectedResource.contains("\"bearer_methods_supported\":[\"header\"]"));
        var mcpResource = (String) geminiController(new McpPrincipalService()).mcpProtectedResourceMetadata().getBody();
        assertTrue(mcpResource.contains("\"resource\":\"" + RESOURCE + "/mcp\""));
    }

    @Test
    void unauthorizedMcpChallengePointsToThePathSpecificMetadata() throws Exception {
        var config = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_ENABLED", "true", "RCM_CENTER_PUBLIC_BASE_URL", RESOURCE));
        var principals = new McpPrincipalService();
        var service = new McpOAuthService(config, principals);
        var filter = new McpOAuthChallengeFilter(config, new McpAuthenticationService(principals, service));
        var request = new MockHttpServletRequest("POST", "/mcp");
        var response = new MockHttpServletResponse();
        filter.doFilter(request, response, new MockFilterChain());
        assertEquals("Bearer resource_metadata=\"" + RESOURCE + "/.well-known/oauth-protected-resource/mcp\"",
                response.getHeader("WWW-Authenticate"));
    }

    @Test
    void geminiAuthorizationAndTokenExchangeValidateClientsAndPreserveState() throws Exception {
        var principals = new McpPrincipalService();
        var bootstrap = principals.issue(new McpPrincipalService.IssueRequest("owner", "owner", 3600L,
                Set.of("mcp:read", "mcp:execute"), Map.of("machine-a", Set.of("command"))));
        var controller = geminiController(principals);
        var verifier = "gemini-oauth-verifier-with-more-than-forty-three-characters";
        var resource = RESOURCE + "/mcp";
        var challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
                MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)));
        var state = "state+one & two/三";
        var page = controller.authorizePage(GEMINI_ID, GEMINI_REDIRECT, "code", "mcp:read offline_access",
                state, challenge, "S256", resource);
        assertEquals(200, page.getStatusCode().value());
        assertTrue(((String) page.getBody()).contains("Google 正在请求"));
        assertTrue(((String) page.getBody()).contains("form-action 'self' https://oauth-redirect.googleusercontent.com"));
        assertEquals(400, controller.authorizePage(GEMINI_ID, "https://oauth-redirect.googleusercontent.com/r/other",
                "code", null, state, challenge, "S256", resource).getStatusCode().value());

        var authorized = controller.authorize(GEMINI_ID, GEMINI_REDIRECT, "code", "mcp:read offline_access",
                state, challenge, "S256", resource, bootstrap.token());
        assertEquals(302, authorized.getStatusCode().value());
        var query = URI.create(authorized.getHeaders().getFirst("Location")).getRawQuery();
        var params = java.util.Arrays.stream(query.split("&"))
                .map(part -> part.split("=", 2)).collect(java.util.stream.Collectors.toMap(
                        part -> part[0], part -> URLDecoder.decode(part[1], StandardCharsets.UTF_8)));
        assertEquals(state, params.get("state"));
        assertEquals(RESOURCE, params.get("iss"));
        var code = params.get("code");

        assertEquals(400, controller.token("authorization_code", GEMINI_ID, "wrong", null,
                GEMINI_REDIRECT, code, verifier, null, resource).getStatusCode().value());
        assertEquals(400, controller.token("authorization_code", GEMINI_ID, GEMINI_SECRET, null,
                GEMINI_REDIRECT, code, "wrong-verifier", null, resource).getStatusCode().value());
        var basic = "Basic " + Base64.getEncoder().encodeToString((URLEncoder.encode(GEMINI_ID, StandardCharsets.UTF_8)
                + ":" + URLEncoder.encode(GEMINI_SECRET, StandardCharsets.UTF_8)).getBytes(StandardCharsets.UTF_8));
        assertEquals(401, controller.token("authorization_code", "other", null, basic,
                GEMINI_REDIRECT, code, verifier, null, resource).getStatusCode().value());
        assertEquals(401, controller.token("authorization_code", GEMINI_ID, GEMINI_SECRET, basic,
                GEMINI_REDIRECT, code, verifier, null, resource).getStatusCode().value());
        var exchanged = controller.token("authorization_code", null, null, basic,
                GEMINI_REDIRECT, code, verifier, null, resource);
        assertEquals(200, exchanged.getStatusCode().value());
        var tokens = (McpOAuthService.TokenResponse) exchanged.getBody();
        assertEquals("bearer", tokens.tokenType());
        var refreshed = controller.token("refresh_token", GEMINI_ID, GEMINI_SECRET, null,
                null, null, null, tokens.refreshToken(), resource);
        assertEquals(200, refreshed.getStatusCode().value());
        assertEquals(tokens.refreshToken(), ((McpOAuthService.TokenResponse) refreshed.getBody()).refreshToken());
        assertEquals(200, controller.token("refresh_token", null, null, basic,
                null, null, null, tokens.refreshToken(), resource).getStatusCode().value());
        assertTrue(principals.revoke(bootstrap.tokenId()));
        assertEquals(400, controller.token("refresh_token", GEMINI_ID, GEMINI_SECRET, null,
                null, null, null, tokens.refreshToken(), resource).getStatusCode().value());
    }

    @Test
    void tokenEndpointAcceptsBothClientAuthenticationMethodsOverHttp() throws Exception {
        var principals = new McpPrincipalService();
        var bootstrap = principals.issue(new McpPrincipalService.IssueRequest("owner", "owner", 3600L,
                Set.of("mcp:read"), Map.of("machine-a", Set.of("task_read"))));
        var config = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_ENABLED", "true", "RCM_CENTER_PUBLIC_BASE_URL", RESOURCE,
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_ID", GEMINI_ID,
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_SECRET", GEMINI_SECRET,
                "RCM_CENTER_OAUTH_GEMINI_REDIRECT_URIS", GEMINI_REDIRECT));
        var service = new McpOAuthService(config, principals);
        var verifier = "gemini-http-verifier-with-more-than-forty-three-characters";
        var challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
                MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)));
        var code = service.issueAuthorizationCode(GEMINI_ID, GEMINI_REDIRECT, challenge, "S256",
                "mcp:read", RESOURCE, bootstrap.token());
        var mvc = MockMvcBuilders.standaloneSetup(new McpOAuthController(config, service)).build();
        var metadata = mvc.perform(get("/.well-known/oauth-authorization-server")).andReturn().getResponse();
        assertEquals(200, metadata.getStatus());
        assertTrue(metadata.getContentAsString().contains("\"response_types_supported\":[\"code\"]"));
        var protectedMetadata = mvc.perform(get("/.well-known/oauth-protected-resource/mcp")).andReturn().getResponse();
        assertEquals(200, protectedMetadata.getStatus());
        assertTrue(protectedMetadata.getContentAsString().contains("\"resource\":\"" + RESOURCE + "/mcp\""));
        var response = mvc.perform(post("/oauth/token").contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .param("grant_type", "authorization_code").param("client_id", GEMINI_ID)
                .param("client_secret", GEMINI_SECRET).param("redirect_uri", GEMINI_REDIRECT)
                .param("code", code.code()).param("code_verifier", verifier))
                .andReturn().getResponse();
        assertEquals(200, response.getStatus());
        assertTrue(response.getContentAsString().contains("\"access_token\""));
        assertTrue(response.getContentAsString().contains("\"refresh_token\""));
        assertTrue(response.getContentAsString().contains("\"token_type\":\"bearer\""));

        var basicCode = service.issueAuthorizationCode(GEMINI_ID, GEMINI_REDIRECT, challenge, "S256",
                "mcp:read", RESOURCE, bootstrap.token());
        var basic = "Basic " + Base64.getEncoder().encodeToString((URLEncoder.encode(GEMINI_ID, StandardCharsets.UTF_8)
                + ":" + URLEncoder.encode(GEMINI_SECRET, StandardCharsets.UTF_8)).getBytes(StandardCharsets.UTF_8));
        var basicResponse = mvc.perform(post("/oauth/token").contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .header("Authorization", basic).param("grant_type", "authorization_code")
                .param("redirect_uri", GEMINI_REDIRECT).param("code", basicCode.code())
                .param("code_verifier", verifier)).andReturn().getResponse();
        assertEquals(200, basicResponse.getStatus());
        assertTrue(basicResponse.getContentAsString().contains("\"access_token\""));
    }

    private static McpOAuthController geminiController(McpPrincipalService principals) {
        var config = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_ENABLED", "true",
                "RCM_CENTER_PUBLIC_BASE_URL", RESOURCE,
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_ID", GEMINI_ID,
                "RCM_CENTER_OAUTH_GEMINI_CLIENT_SECRET", GEMINI_SECRET,
                "RCM_CENTER_OAUTH_GEMINI_REDIRECT_URIS", GEMINI_REDIRECT));
        return new McpOAuthController(config, new McpOAuthService(config, principals));
    }

    private static McpOAuthController controller() {
        var config = new CenterOAuthConfig(Map.of(
                "RCM_CENTER_OAUTH_ENABLED", "true",
                "RCM_CENTER_PUBLIC_BASE_URL", RESOURCE));
        return new McpOAuthController(config, new McpOAuthService(config, new McpPrincipalService()));
    }
}
