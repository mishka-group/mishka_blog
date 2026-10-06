import Config

config :mishka_blog, MishkaBlog.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mishka_blog_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
