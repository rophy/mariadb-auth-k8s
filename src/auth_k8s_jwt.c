/*
 * MariaDB Kubernetes ServiceAccount Authentication Plugin - Server Side
 *
 * Validates ServiceAccount tokens using JWT cryptographic verification
 * with OIDC discovery (no TokenReview API needed).
 */

#include <mysql/plugin_auth.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "jwt_crypto.h"

/* Plugin version */
#define PLUGIN_VERSION 0x0300

/*
 * Plugin initialization
 *
 * Called when the plugin is first loaded.
 * Auto-configures for local Kubernetes cluster.
 */
static int auth_k8s_plugin_init(void *p)
{
    fprintf(stderr, "K8s JWT Auth: Initializing plugin...\n");

    /* Initialize JWT validator (auto-configures for local cluster) */
    if (jwt_crypto_init() != 0) {
        fprintf(stderr, "K8s JWT Auth: Failed to initialize JWT validator\n");
        return 1;
    }

    fprintf(stderr, "K8s JWT Auth: Plugin initialized successfully\n");
    return 0;
}

/*
 * Plugin deinitialization
 */
static int auth_k8s_plugin_deinit(void *p)
{
    fprintf(stderr, "K8s JWT Auth: Cleaning up plugin...\n");
    jwt_crypto_cleanup();
    return 0;
}

/*
 * Server authentication function
 *
 * This function is called when a client attempts to authenticate.
 *
 * @param vio - Communication channel with the client
 * @param info - Server connection information
 * @return 0 on success, 1 on failure
 */
static int auth_k8s_server(MYSQL_PLUGIN_VIO *vio, MYSQL_SERVER_AUTH_INFO *info)
{
    unsigned char *packet;
    int packet_len;
    char *token = NULL;
    k8s_jwt_token_info_t token_info;
    char error_msg[256] = {0};

    /* Send a request to the client for the ServiceAccount token */
    if (vio->write_packet(vio, (unsigned char *)"", 0))
    {
        return CR_ERROR;
    }

    /* Read the token from the client */
    packet_len = vio->read_packet(vio, &packet);
    if (packet_len < 0)
    {
        return CR_ERROR;
    }

    /* Check if token was provided */
    if (packet_len == 0)
    {
        fprintf(stderr, "K8s JWT Auth: No token provided\n");
        info->password_used = PASSWORD_USED_NO;
        return CR_ERROR;
    }

    info->password_used = PASSWORD_USED_YES;

    /* Null-terminate the token string */
    token = malloc(packet_len + 1);
    if (!token) {
        fprintf(stderr, "K8s JWT Auth: Memory allocation failed\n");
        return CR_ERROR;
    }
    memcpy(token, packet, packet_len);
    token[packet_len] = '\0';

    /* Log token info (preview only for security) */
    char token_preview[50] = {0};
    int preview_len = packet_len < 40 ? packet_len : 40;
    memcpy(token_preview, token, preview_len);
    fprintf(stderr, "K8s JWT Auth: Received token (length=%d, preview=%.40s...)\n",
            packet_len, token_preview);
    fprintf(stderr, "K8s JWT Auth: Authenticating user '%s'\n", info->user_name);

    /* Validate JWT token */
    int valid = k8s_jwt_validate_token(token, &token_info, error_msg);
    free(token);

    if (!valid || !token_info.authenticated) {
        fprintf(stderr, "K8s JWT Auth: Token validation failed: %s\n",
                error_msg[0] ? error_msg : "Unknown error");
        return CR_ERROR;
    }

    /* Build expected username from MariaDB user: namespace/serviceaccount */
    char expected_user[K8S_MAX_NAMESPACE_LEN + K8S_MAX_NAME_LEN + 2];
    snprintf(expected_user, sizeof(expected_user), "%s/%s",
             token_info.namespace, token_info.service_account);

    /* Verify that the MariaDB username matches the ServiceAccount */
    if (strcmp(info->user_name, expected_user) != 0) {
        fprintf(stderr, "K8s JWT Auth: User mismatch. Expected '%s', got '%s'\n",
                expected_user, info->user_name);
        fprintf(stderr, "K8s JWT Auth: Token is for %s/%s\n",
                token_info.namespace, token_info.service_account);
        return CR_ERROR;
    }

    fprintf(stderr, "K8s JWT Auth: ✅ Authentication successful for %s/%s\n",
            token_info.namespace, token_info.service_account);
    fprintf(stderr, "K8s JWT Auth: Token issuer: %s\n", token_info.issuer);
    fprintf(stderr, "K8s JWT Auth: Token expires: %ld\n", (long)token_info.expiration);

    return CR_OK;
}

/*
 * Plugin descriptor structure
 */
static struct st_mysql_auth auth_k8s_handler = {
    MYSQL_AUTHENTICATION_INTERFACE_VERSION,
    "mysql_clear_password",  /* Client plugin name - use built-in clear password plugin */
    auth_k8s_server,         /* Server authentication function */
    NULL,                    /* Generate auth string (not used) */
    NULL                     /* Validate auth string (not used) */
};

/*
 * Plugin declaration
 */
mysql_declare_plugin(auth_k8s)
{
    MYSQL_AUTHENTICATION_PLUGIN,
    &auth_k8s_handler,
    "auth_k8s",
    "MariaDB K8s Auth Plugin Contributors",
    "Kubernetes ServiceAccount Authentication with JWT validation",
    PLUGIN_LICENSE_GPL,
    auth_k8s_plugin_init,    /* Plugin init */
    auth_k8s_plugin_deinit,  /* Plugin deinit */
    PLUGIN_VERSION,
    NULL,                    /* Status variables */
    NULL,                    /* System variables */
    NULL,                    /* Config options */
    0                        /* Flags */
}
mysql_declare_plugin_end;
