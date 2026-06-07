import Config

config :nebula_api,
  nodes: [
    "demo_app@demo_app": [:nebula, :app],
    "worker1@worker1": [:nebula, :worker],
    "worker2@worker2": [:nebula, :worker],
    "worker3@worker3": [:nebula, :worker],
    "db@db": [:nebula, :db]
  ],
  registered_modules: [Db.Store, Worker.Job]

config :libcluster,
  topologies: [
    demo: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [
          :"demo_app@demo_app",
          :"worker1@worker1",
          :"worker2@worker2",
          :"worker3@worker3",
          :"db@db"
        ]
      ]
    ]
  ]
