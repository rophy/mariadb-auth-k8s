const axios = require('axios');
const https = require('https');
const fs = require('fs');

/**
 * OIDC discovery with caching
 */
class OIDCDiscovery {
  constructor(ttl = 3600 * 1000) { // Default 1 hour
    this.cache = new Map();
    this.ttl = ttl;
  }

  /**
   * Get OIDC configuration from cache or fetch if expired
   * @param {string} issuer - OIDC issuer URL
   * @param {object} cluster - Cluster configuration (for custom CA and auth)
   */
  async getConfiguration(issuer, cluster = null) {
    const cached = this.cache.get(issuer);

    // Return cached if not expired
    if (cached && Date.now() < cached.expiresAt) {
      return cached.config;
    }

    // Fetch fresh configuration
    const config = await this.fetchConfiguration(issuer, cluster);

    // Cache with TTL
    this.cache.set(issuer, {
      config,
      expiresAt: Date.now() + this.ttl
    });

    return config;
  }

  /**
   * Fetch OIDC discovery document
   */
  async fetchConfiguration(issuer, cluster = null) {
    // Construct well-known URL
    let discoveryUrl = issuer;
    if (!discoveryUrl.endsWith('/')) {
      discoveryUrl += '/';
    }
    discoveryUrl += '.well-known/openid-configuration';

    try {
      const axiosConfig = {
        timeout: 10000,
        headers: {
          'Accept': 'application/json'
        }
      };

      // Add custom CA cert if provided
      if (cluster && cluster.ca_cert_path && fs.existsSync(cluster.ca_cert_path)) {
        const ca = fs.readFileSync(cluster.ca_cert_path, 'utf8');
        axiosConfig.httpsAgent = new https.Agent({
          ca: ca,
          rejectUnauthorized: true
        });
      }

      // Add bearer token if provided (for Kubernetes API server)
      if (cluster && cluster.token_path && fs.existsSync(cluster.token_path)) {
        const token = fs.readFileSync(cluster.token_path, 'utf8').trim();
        axiosConfig.headers['Authorization'] = `Bearer ${token}`;
      }

      const response = await axios.get(discoveryUrl, axiosConfig);

      if (!response.data || !response.data.jwks_uri) {
        throw new Error('Invalid OIDC discovery response: missing jwks_uri');
      }

      console.log(`[OIDCDiscovery] Fetched OIDC config from ${discoveryUrl}`);
      console.log(`[OIDCDiscovery] JWKS URI: ${response.data.jwks_uri}`);

      return response.data;
    } catch (error) {
      console.error(`[OIDCDiscovery] Failed to fetch OIDC config from ${discoveryUrl}:`, error.message);
      throw new Error(`oidc_discovery_failed: ${error.message}`);
    }
  }

  /**
   * Clear cache entry
   */
  invalidate(issuer) {
    this.cache.delete(issuer);
  }

  /**
   * Clear all cache
   */
  clear() {
    this.cache.clear();
  }
}

module.exports = OIDCDiscovery;
