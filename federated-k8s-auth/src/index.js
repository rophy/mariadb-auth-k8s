const ClusterConfig = require('./cluster-config');
const createServer = require('./server');

/**
 * Main entry point
 */
async function main() {
  console.log('[TokenValidator] Starting Token Validator API...');

  // Initialize cluster configuration
  const clusterConfig = new ClusterConfig();
  const configPath = process.env.CLUSTER_CONFIG_PATH || null;

  try {
    await clusterConfig.initialize(configPath);
  } catch (error) {
    console.error('[TokenValidator] Failed to initialize cluster config:', error);
    process.exit(1);
  }

  if (clusterConfig.count() === 0) {
    console.error('[TokenValidator] No clusters configured. Exiting.');
    process.exit(1);
  }

  // Create and start server
  const app = createServer(clusterConfig);
  const port = process.env.PORT || 8080;

  app.listen(port, () => {
    console.log(`[TokenValidator] Server listening on port ${port}`);
    console.log(`[TokenValidator] Configured clusters: ${clusterConfig.listClusters().join(', ')}`);
  });
}

// Handle uncaught errors
process.on('uncaughtException', (error) => {
  console.error('[TokenValidator] Uncaught exception:', error);
  process.exit(1);
});

process.on('unhandledRejection', (error) => {
  console.error('[TokenValidator] Unhandled rejection:', error);
  process.exit(1);
});

// Start the server
main();
