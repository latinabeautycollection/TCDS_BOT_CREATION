module.exports = {
  apps: [
    {
      name: 'r1d-scheduler',
      script: 'scripts/retail-automation/r1d/scheduler-service.ts',
      interpreter: 'node',
      interpreter_args: '--import tsx',
      autorestart: true,
      restart_delay: 5000,
      env: {
        R1D_SCHEDULER_INTERVAL_MS: '60000',
        R1D_MATERIALIZE_LIMIT: '500'
      }
    },
    {
      name: 'r1d-dispatcher',
      script: 'scripts/retail-automation/r1d/worker-dispatcher.ts',
      interpreter: 'node',
      interpreter_args: '--import tsx',
      instances: 4,
      exec_mode: 'fork',
      autorestart: true,
      restart_delay: 5000,
      env: {
        R1D_IDLE_MIN_MS: '1000',
        R1D_IDLE_MAX_MS: '5000'
      }
    }
  ]
};
