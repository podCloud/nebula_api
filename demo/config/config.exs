import Config

config :nebula_api,
  nodes: [
    "demo_app@demo_app.test": [:nebula, :app],
    "worker1@worker1.test": [:nebula, :worker],
    "worker2@worker2.test": [:nebula, :worker],
    "worker3@worker3.test": [:nebula, :worker],
    "db@db.test": [:nebula, :db]
  ],
  # Static (like nebula): both domain modules are loaded on every node (the worker
  # and db apps run everywhere — see demo/mix.exs apps/1), so APIServer can register
  # them on any node. Each node only serves the methods it compiled as LOCAL.
  registered_modules: [Db.Store, Worker.Job]

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
