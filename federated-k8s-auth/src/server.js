const express = require('express');
const TokenValidator = require('./validator');

/**
 * Create Express HTTP server
 */
function createServer(clusterConfig) {
  const app = express();
  const validator = new TokenValidator(clusterConfig);

  // Middleware
  app.use(express.json());

  // Request logging
  app.use((req, res, next) => {
    console.log(`${new Date().toISOString()} ${req.method} ${req.path}`);
    next();
  });

  // Health check endpoint
  app.get('/health', (req, res) => {
    res.json({
      status: 'ok',
      clusters: clusterConfig.count()
    });
  });

  // List clusters (debug endpoint)
  app.get('/api/v1/clusters', (req, res) => {
    const clusters = clusterConfig.listClusters();
    res.json({
      clusters: clusters,
      count: clusters.length
    });
  });

  // Validate token endpoint
  app.post('/api/v1/validate', async (req, res) => {
    const { cluster_name, token } = req.body;

    // Validate request body
    if (!cluster_name || typeof cluster_name !== 'string') {
      return res.status(400).json({
        authenticated: false,
        error: 'invalid_request',
        message: 'Missing or invalid cluster_name'
      });
    }

    if (!token || typeof token !== 'string') {
      return res.status(400).json({
        authenticated: false,
        error: 'invalid_request',
        message: 'Missing or invalid token'
      });
    }

    // Validate token
    const result = await validator.validateToken(cluster_name, token);

    // Return appropriate HTTP status
    if (result.authenticated) {
      res.status(200).json(result);
    } else if (result.error === 'cluster_not_found') {
      res.status(400).json(result);
    } else if (result.error === 'internal_error') {
      res.status(500).json(result);
    } else {
      res.status(401).json(result);
    }
  });

  // 404 handler
  app.use((req, res) => {
    res.status(404).json({
      error: 'not_found',
      message: 'Endpoint not found'
    });
  });

  // Error handler
  app.use((err, req, res, next) => {
    console.error('[Server] Unhandled error:', err);
    res.status(500).json({
      authenticated: false,
      error: 'internal_error',
      message: 'Internal server error'
    });
  });

  return app;
}

module.exports = createServer;
