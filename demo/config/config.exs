import Config

config :nebula_api,
  nodes: [
    "demo_app@demo_app.test": [:nebula, :app],
    "worker1@worker1.test": [:nebula, :worker],
    "worker2@worker2.test": [:nebula, :worker],
    "worker3@worker3.test": [:nebula, :worker],
    "db@db.test": [:nebula, :db]
  ]

# No registered_modules: each app wires a NebulaAPI.Server into its own supervision
# tree (via nebula_api_server/0), which discovers its modules and starts a worker
# per locally-served one. See apps/*/lib/*/application.ex.

config :libcluster,
  topologies: [
    demo: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [
          :"demo_app@demo_app.test",
          :"worker1@worker1.test",
          :"worker2@worker2.test",
          :"worker3@worker3.test",
          :"db@db.test"
        ]
      ]
    ]
  ]
