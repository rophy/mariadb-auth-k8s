const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const { jwtVerify, decodeJwt } = require('jose');

/**
 * Load and manage cluster configurations
 */
class ClusterConfig {
  constructor() {
    this.clusters = new Map();
  }

  /**
   * Initialize cluster configurations
   * Auto-detects local cluster if running in Kubernetes
   * Loads external clusters from YAML file
   */
  async initialize(configPath = null) {
    // Auto-detect local cluster
    const localCluster = await this.detectLocalCluster();
    if (localCluster) {
      this.clusters.set('local', localCluster);
      console.log('[ClusterConfig] Auto-detected local cluster');
    }

    // Load external clusters from config file
    if (configPath && fs.existsSync(configPath)) {
      await this.loadFromFile(configPath);
    } else {
      // Check for config in multiple locations
      const configPaths = [
        '/etc/token-validator/clusters.yaml',
        path.join(process.cwd(), 'config', 'clusters.yaml'),
        path.join(process.cwd(), 'clusters.yaml')
      ];

      for (const filePath of configPaths) {
        if (fs.existsSync(filePath)) {
          await this.loadFromFile(filePath);
          break;
        }
      }
    }

    console.log(`[ClusterConfig] Loaded ${this.clusters.size} cluster(s): ${Array.from(this.clusters.keys()).join(', ')}`);
  }

  /**
   * Detect local Kubernetes cluster by checking ServiceAccount files
   */
  async detectLocalCluster() {
    const saPath = '/var/run/secrets/kubernetes.io/serviceaccount';
    const tokenPath = path.join(saPath, 'token');
    const caPath = path.join(saPath, 'ca.crt');

    if (!fs.existsSync(tokenPath) || !fs.existsSync(caPath)) {
      return null;
    }

    try {
      // Read token to extract issuer
      const token = fs.readFileSync(tokenPath, 'utf8').trim();
      const decoded = decodeJwt(token);

      return {
        name: 'local',
        issuer: decoded.iss,
        api_server: 'https://kubernetes.default.svc',
        ca_cert_path: caPath,
        token_path: tokenPath,
        auto: true,
        // Default: 1 hour (can be overridden by config file)
        max_token_ttl: 3600
      };
    } catch (error) {
      console.error('[ClusterConfig] Failed to auto-detect local cluster:', error.message);
      return null;
    }
  }

  /**
   * Load cluster configurations from YAML file
   */
  async loadFromFile(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      const config = yaml.load(content);

      if (!config.clusters || !Array.isArray(config.clusters)) {
        console.warn('[ClusterConfig] No clusters found in config file');
        return;
      }

      for (const cluster of config.clusters) {
        // Handle auto-detection entries (merge with auto-detected config)
        if (cluster.auto) {
          const existingCluster = this.clusters.get(cluster.name || 'local');
          if (existingCluster) {
            // Merge config file settings with auto-detected settings
            Object.assign(existingCluster, cluster);
            console.log(`[ClusterConfig] Updated auto-detected cluster: ${existingCluster.name}`);
          }
          continue;
        }

        // Validate required fields
        if (!cluster.name) {
          console.warn('[ClusterConfig] Skipping cluster without name');
          continue;
        }

        // Only require api_server and issuer for external clusters
        if (!cluster.api_server || !cluster.issuer) {
          console.warn(`[ClusterConfig] Skipping cluster ${cluster.name}: missing api_server or issuer`);
          continue;
        }

        this.clusters.set(cluster.name, cluster);
        console.log(`[ClusterConfig] Loaded cluster: ${cluster.name}`);
      }
    } catch (error) {
      console.error('[ClusterConfig] Failed to load config file:', error.message);
      throw error;
    }
  }

  /**
   * Get cluster configuration by name
   */
  getCluster(name) {
    return this.clusters.get(name);
  }

  /**
   * Get all cluster names
   */
  listClusters() {
    return Array.from(this.clusters.keys());
  }

  /**
   * Get cluster count
   */
  count() {
    return this.clusters.size;
  }
}

module.exports = ClusterConfig;
