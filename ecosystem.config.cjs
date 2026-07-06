module.exports = {
  apps: [
    {
      name: "pqp-api",
      script: "npm",
      args: "run dev",
      cwd: "/srv/pqp",
      env: {
        NODE_ENV: "production",
        PORT: "8088"
      }
    }
  ]
};
