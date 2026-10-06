import Config

config :mishka_blog,
  ecto_repos: [MishkaBlog.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [MishkaBlog]

# Which repo the resources write through and which endpoint they broadcast on — the same two settings
# the CMS sets for itself. Read with `Application.compile_env!/2` in `postgres do repo … end` and
# `pub_sub do module … end`, which is what lets these resources compile outside the CMS at all.
# Compile-time, so it costs nothing per query.
# Whose admin routes `extension_routes(:admin)` mounts — on its own, this extension's.
config :mishka_cms_core, extensions: [MishkaCmsCoreWeb, MishkaBlogWeb]

config :mishka_cms_core,
  repo: MishkaBlog.Repo,
  endpoint: MishkaBlog.TestEndpoint,
  host_app: :mishka_blog

# JSON:API speaks `application/vnd.api+json`, which Plug does not know by default — without this the
# `:accepts ["json"]` plug answers 406 to every request the suite makes. `:mime` reads this at compile
# time, so changing it needs `mix deps.compile mime --force`.
config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

import_config "#{config_env()}.exs"
