CMAKE_MINIMUM_REQUIRED(VERSION 3.5)
PROJECT(mariadb_auth_k8s C)

# Build options: Choose validation method
OPTION(USE_TOKEN_VALIDATOR_API "Use Token Validator API (production, multi-cluster)" OFF)
OPTION(USE_JWT_VALIDATION "Use JWT validation instead of TokenReview API" ON)

# Find MariaDB server-side plugin headers (downloaded from source)
FIND_PATH(MARIADB_SERVER_INCLUDE_DIR
    NAMES mysql/plugin.h
    PATHS
        /opt/include
        /usr/local/include/mariadb-server
        ${CMAKE_SOURCE_DIR}/include
    NO_DEFAULT_PATH
)

IF(NOT MARIADB_SERVER_INCLUDE_DIR)
    MESSAGE(FATAL_ERROR "MariaDB server plugin headers not found. Should be at /usr/local/include/mariadb-server or include/")
ENDIF()

MESSAGE(STATUS "Found MariaDB server headers: ${MARIADB_SERVER_INCLUDE_DIR}")

# Include server headers
INCLUDE_DIRECTORIES(${MARIADB_SERVER_INCLUDE_DIR})

# Determine which libraries are needed based on build options
IF(USE_TOKEN_VALIDATOR_API)
    MESSAGE(STATUS "Token Validator API enabled (production, multi-cluster)")
    # Token Validator API needs: libcurl, json-c
    FIND_PACKAGE(CURL REQUIRED)
    FIND_PACKAGE(PkgConfig REQUIRED)
    PKG_CHECK_MODULES(JSON_C REQUIRED json-c)
ELSEIF(USE_JWT_VALIDATION)
    MESSAGE(STATUS "JWT validation enabled - using OpenSSL")
    # JWT validation needs: libcurl, json-c, OpenSSL
    FIND_PACKAGE(CURL REQUIRED)
    FIND_PACKAGE(PkgConfig REQUIRED)
    PKG_CHECK_MODULES(JSON_C REQUIRED json-c)
    FIND_PACKAGE(OpenSSL REQUIRED)
ELSE()
    MESSAGE(STATUS "TokenReview API validation enabled")
    # TokenReview API needs: libcurl, json-c
    FIND_PACKAGE(CURL REQUIRED)
    FIND_PACKAGE(PkgConfig REQUIRED)
    PKG_CHECK_MODULES(JSON_C REQUIRED json-c)
ENDIF()

# Compiler flags matching MariaDB plugin standards
SET(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wextra -fPIC")
SET(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -D_GNU_SOURCE")

# Define MYSQL_DYNAMIC_PLUGIN for dynamic library loading
ADD_DEFINITIONS(-DMYSQL_DYNAMIC_PLUGIN)

# Build server-side plugin as a module
IF(USE_TOKEN_VALIDATOR_API)
    # Token Validator API client version - production, multi-cluster
    ADD_LIBRARY(auth_k8s MODULE src/auth_k8s_validator_api.c)
    TARGET_LINK_LIBRARIES(auth_k8s ${CURL_LIBRARIES} ${JSON_C_LIBRARIES})
    TARGET_INCLUDE_DIRECTORIES(auth_k8s PRIVATE ${CURL_INCLUDE_DIRS} ${JSON_C_INCLUDE_DIRS})
ELSEIF(USE_JWT_VALIDATION)
    # JWT validation version - pure OpenSSL implementation
    ADD_LIBRARY(auth_k8s MODULE src/auth_k8s_jwt.c src/jwt_crypto.c)
    TARGET_LINK_LIBRARIES(auth_k8s ${CURL_LIBRARIES} ${JSON_C_LIBRARIES} OpenSSL::SSL OpenSSL::Crypto)
    TARGET_INCLUDE_DIRECTORIES(auth_k8s PRIVATE ${CURL_INCLUDE_DIRS} ${JSON_C_INCLUDE_DIRS})
ELSE()
    # TokenReview API version
    ADD_LIBRARY(auth_k8s MODULE src/auth_k8s_tokenreview.c src/tokenreview_api.c)
    TARGET_LINK_LIBRARIES(auth_k8s ${CURL_LIBRARIES} ${JSON_C_LIBRARIES})
    TARGET_INCLUDE_DIRECTORIES(auth_k8s PRIVATE ${CURL_INCLUDE_DIRS} ${JSON_C_INCLUDE_DIRS})
ENDIF()

# Remove the 'lib' prefix from the output file
SET_TARGET_PROPERTIES(auth_k8s PROPERTIES PREFIX "")

# Installation
# Determine plugin directory
IF(NOT PLUGIN_DIR)
    EXECUTE_PROCESS(
        COMMAND mysql_config --plugindir
        OUTPUT_VARIABLE PLUGIN_DIR
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
ENDIF()

IF(NOT PLUGIN_DIR)
    # Fallback plugin directory
    SET(PLUGIN_DIR "${CMAKE_INSTALL_PREFIX}/lib/mysql/plugin")
ENDIF()

MESSAGE(STATUS "Plugin directory: ${PLUGIN_DIR}")

# Install targets
INSTALL(TARGETS auth_k8s DESTINATION ${PLUGIN_DIR})

MESSAGE(STATUS "")
MESSAGE(STATUS "==========================================")
MESSAGE(STATUS "MariaDB K8s Auth Plugin Build Configuration")
MESSAGE(STATUS "==========================================")
MESSAGE(STATUS "Server plugin: auth_k8s.so")
IF(USE_TOKEN_VALIDATOR_API)
    MESSAGE(STATUS "Validation method: Token Validator API (production)")
    MESSAGE(STATUS "Dependencies: libcurl, libjson-c")
    MESSAGE(STATUS "Note: Requires Token Validator API service running")
ELSEIF(USE_JWT_VALIDATION)
    MESSAGE(STATUS "Validation method: JWT with OIDC discovery (OpenSSL)")
    MESSAGE(STATUS "Dependencies: libcurl, libjson-c, OpenSSL")
ELSE()
    MESSAGE(STATUS "Validation method: TokenReview API")
    MESSAGE(STATUS "Dependencies: libcurl, libjson-c")
ENDIF()
MESSAGE(STATUS "Install to: ${PLUGIN_DIR}")
MESSAGE(STATUS "==========================================")
MESSAGE(STATUS "")
